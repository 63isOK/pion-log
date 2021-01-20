# 协程池

[开源项目workerpool](https://github.com/gammazero/workerpool)

## 说明

这个库是通过限制系统资源来达到目的,而不是通过限制任务数量来实现.

直接看源码:

    func New(maxWorkers int) *WorkerPool {
      if maxWorkers < 1 {
        maxWorkers = 1
      }

      pool := &WorkerPool{
        maxWorkers:  maxWorkers,
        taskQueue:   make(chan func(), 1),
        workerQueue: make(chan func()),
        stopSignal:  make(chan struct{}),
        stoppedChan: make(chan struct{}),
      }

      // 开始调度
      go pool.dispatch()

      return pool
    }

构造参数指明了最大协程数量,并不是实时都保持这个数量的协程,
而是在没有任务的情况下,协程会优雅退出,直到所有工作协程.

下面用tasks表示任务,用workers表示工作协程.

    type WorkerPool struct {
      maxWorkers   int
      taskQueue    chan func()
      workerQueue  chan func()
      stoppedChan  chan struct{}
      stopSignal   chan struct{}
      waitingQueue deque.Deque
      stopLock     sync.Mutex
      stopOnce     sync.Once
      stopped      bool
      waiting      int32
      wait         bool
    }

这是构造函数构造的对象,工作池对象.里面有task信道,也有worker信道.

    func (p *WorkerPool) Size() int {
      return p.maxWorkers
    }

获取设置的最大工作协程数量.

    func (p *WorkerPool) Stop() {
      p.stop(false)
    }

结束,排队的任务会被丢弃,等待当前任务运行完就会关闭worker,
空闲worker会被关闭.Stop调用之后,就不能再提交新的任务了.

dispatch(),是将已排队的task分配到一个可用的worker上.
这里面的分配过程非常有趣.

    func (p *WorkerPool) dispatch() {
      defer close(p.stoppedChan)

      // 空闲检查间隔设置为2s
      // 一旦检测到没有worker在运行,就会释放worker
      timeout := time.NewTimer(idleTimeout)
      var workerCount int
      var idle bool

    Loop:
      for {

        // 如果等待队列未空,所有新提交的task都会添加到等待队列
        // 一旦有空闲worker时,都会先从等待队列的头部取task丢给worker
        // 这里的continue用的非常妙,将整个分配规则分成了两段:
        // 等待队列未空;等待队列空的场景.
        if p.waitingQueue.Len() != 0 {
          if !p.processWaitingQueue() {
            break Loop
          }
          continue
        }

        // 等待队列为空,说明可能有空闲worker
        select {

        // 新提交一个task,此时有两种情况:
        // worker数量达到最大,每个worker都在处理task,此时task会丢到等待队列中
        // 直接将task丢给具体的worker,如果worker数量没达到最大,新建worker
        case task, ok := <-p.taskQueue:
          if !ok {
            break Loop
          }
          // Got a task to do.
          select {
          case p.workerQueue <- task:
          default:
            // Create a new worker, if not at max.
            if workerCount < p.maxWorkers {
              go startWorker(task, p.workerQueue)
              workerCount++
            } else {
              // Enqueue task to be executed by next available worker.
              p.waitingQueue.PushBack(task)
              atomic.StoreInt32(&p.waiting, int32(p.waitingQueue.Len()))
            }
          }
          idle = false

        // 间隔两秒,做一次空闲检查
        // 空闲检查的目的是释放一些空闲worker
        case <-timeout.C:
          // Timed out waiting for work to arrive.  Kill a ready worker if
          // pool has been idle for a whole timeout.
          if idle && workerCount > 0 {
            if p.killIdleWorker() {
              workerCount--
            }
          }
          idle = true
          timeout.Reset(idleTimeout)
        }
      }

      // 根据wait标识,来将等待队列中所有的task执行完
      if p.wait {
        p.runQueuedTasks()
      }

      // 当worker空闲后,释放掉
      for workerCount > 0 {
        p.workerQueue <- nil
        workerCount--
      }

      // 停止计时器
      timeout.Stop()
    }

总的来说,这个分配方法非常有意思,而且代码优雅.

下面来看下在分配方法中,使用到的其他函数:

这是等待队列未空时的处理逻辑:

    func (p *WorkerPool) processWaitingQueue() bool {
      select {

      // 新提交的task都添加到等待队列尾
      case task, ok := <-p.taskQueue:
        if !ok {
          return false
        }
        p.waitingQueue.PushBack(task)

      // 有空闲worker时,先处理等待队列的头
      case p.workerQueue <- p.waitingQueue.Front().(func()):
        p.waitingQueue.PopFront()
      }
      atomic.StoreInt32(&p.waiting, int32(p.waitingQueue.Len()))
      return true
    }

这是worker数量还未达到最大,需要新建worker来处理task的情况:

    func startWorker(task func(), workerQueue chan func()) {
      task()
      go worker(workerQueue)
    }

    func worker(workerQueue chan func()) {
      for task := range workerQueue {

        // 如果task是nil,当前worker就结束了.
        if task == nil {
          return
        }
        task()
      }
    }

    func (p *WorkerPool) killIdleWorker() bool {
      select {

      // 发送一个nil task,就会释放一个worker
      case p.workerQueue <- nil:
        return true

      // 如果没有空闲worker就不杀了
      default:
        return false
      }
    }

这里非常有意思,startWroker本身就是在新协程中执行,第一件事是执行task,
之后做了一件非常有意思的事:创建一个worker,
这个worker才是池里面的工作协程,而startWorker在task执行完之后就会结束.
所以这个池的实现才非常有意思.

实际上,是有多个worker同时在监听workerQueue,至于是哪个协程获取到,
就看Go的调度了.

最后还提供了标识符来确定整个分配结束时,是否需要将等待队列中的任务执行完:

    func (p *WorkerPool) runQueuedTasks() {
      for p.waitingQueue.Len() != 0 {
        p.workerQueue <- p.waitingQueue.PopFront().(func())
        atomic.StoreInt32(&p.waiting, int32(p.waitingQueue.Len()))
      }
    }

我们来看一下提交:

    func (p *WorkerPool) Submit(task func()) {
      if task != nil {
        p.taskQueue <- task
      }
    }

    func (p *WorkerPool) SubmitWait(task func()) {
      if task == nil {
        return
      }
      doneChan := make(chan struct{})
      p.taskQueue <- func() {
        task()
        close(doneChan)
      }
      <-doneChan
    }

Submit就是常规的提交,SubmitWait做了一些小小的扩展,
这些扩展会阻塞,直到task执行完.因为任务队列是 `chan func()`,
所以扩展非常容易.

其次提交的都是func(){}, 参数需要通过闭包传进去,返回值需要通过信道传出来.

    func (p *WorkerPool) WaitingQueueSize() int {
      return int(atomic.LoadInt32(&p.waiting))
    }

获取等待队列的任务数.

下面是暂停pause:

    func (p *WorkerPool) Pause(ctx context.Context) {
      p.stopLock.Lock()
      defer p.stopLock.Unlock()
      if p.stopped {
        return
      }
      ready := new(sync.WaitGroup)
      ready.Add(p.maxWorkers)
      for i := 0; i < p.maxWorkers; i++ {
        p.Submit(func() {
          ready.Done()
          select {
          case <-ctx.Done():
          case <-p.stopSignal:
          }
        })
      }
      // Wait for workers to all be paused
      ready.Wait()
    }

从源码上看,是提交了maxWorkers个task,只有当上下文取消或超时,或有明确的结束信号,
task才会结束,而且这个Pause也是阻塞的.

结束信号,其实是调用stop函数.

    func (p *WorkerPool) Stop() {
      p.stop(false)
    }

    func (p *WorkerPool) StopWait() {
      p.stop(true)
    }

    func (p *WorkerPool) stop(wait bool) {
      p.stopOnce.Do(func() {
        close(p.stopSignal)
        p.stopLock.Lock()
        p.stopped = true
        p.stopLock.Unlock()
        p.wait = wait
        close(p.taskQueue)
      })
      <-p.stoppedChan
    }

在stop的最后,会监听stoppedChan信道,这是在等dispatch函数退出.
stopSignal信号,是用于通知Pause退出.
