# gammazero/deque

这里提供的是一个环队数据结构.

    const minCapacity = 16

最小容量是16

    type Deque struct {
      buf    []interface{}
      head   int
      tail   int
      count  int
      minCap int
    }

数据结构,字段不对外暴露,都是通过方法暴露的.
这里是没有锁,所以在并发情况下,需要在调用方维护竞争关系.
这里的缓冲是`[]interface{}`,所以队列里存任何值都是可以的.
对于环队来说,几个最基本的信息都有:

- 头和尾 head/tail
- 初始设置的最小容量 minCap
- 当前元素个数 count

下面先分析非暴露的函数:

    func (q *Deque) resize() {
      newBuf := make([]interface{}, q.count<<1)
      if q.tail > q.head {
        copy(newBuf, q.buf[q.head:q.tail])
      } else {
        n := copy(newBuf, q.buf[q.head:])
        copy(newBuf[n:], q.buf[:q.tail])
      }

      q.head = 0
      q.tail = q.count
      q.buf = newBuf
    }

resize做的事情非常有意思:将当前缓冲大小改为元素个数的两倍.

    func (q *Deque) growIfFull() {
      if len(q.buf) == 0 {
        if q.minCap == 0 {
          q.minCap = minCapacity
        }
        q.buf = make([]interface{}, q.minCap)
        return
      }
      if q.count == len(q.buf) {
        q.resize()
      }
    }

growIfFull除了在缓冲满时,调用resize将缓冲长度翻倍,
还可以用作缓冲的初始化.

    func (q *Deque) shrinkIfExcess() {
      if len(q.buf) > q.minCap && (q.count<<2) == len(q.buf) {
        q.resize()
      }
    }

缓冲过多需要缩小时,条件很特殊:

- 缓冲长度大于最小阈值
- 实际元素数量只占了1/4的缓冲

再看下调用时机: PopFront/PopBack,最后都会调用shrinkIfExcess,
所以缓冲缩小的条件就不那么怪异了.

再看下growIfFull的调用时机:PushBack/PushFront的开始都会调用.

    func (q *Deque) prev(i int) int {
      return (i - 1) & (len(q.buf) - 1)
    }

    func (q *Deque) next(i int) int {
      return (i + 1) & (len(q.buf) - 1)
    }

理解这个写法之前,先说明一个事:

m%n,如果m是2的k次方,取模问题可以转换成取n的低位(总共取k位),
实现方式可转换成n和k位1做按位与操作,k位1正好等于(m-1),
所以整个取模问题可转换成 m%n = n&(m-1)

需要注意:这套逻辑仅适合m是2的k次方时才成立.

回到代码,q.buf,这个的长度一定是2的k次方:

- 初始化时是16, 2的4次方
- 设置时,设置的是2的幂
- resize时, 长度是根据元素个数来翻倍的
  - growIfFull,是缓冲满了再扩容,此时元素个数是之前扩容的长度
  - shrinkIfExcess,是元素个数达到1/4了缩小一般

现在再看之前一些奇怪的地方,就觉得非常巧妙了,
不管缓冲如何扩缩,长度都是2的k次方.

    make([]interface{}, q.minCap)
    make([]interface{}, q.count<<1)

在申请缓冲时,就指定了长度,同时容量和长度是一致的.

所以prev和next就是取缓冲的第几个.
使用到这种取模方法,会自动在首尾进行跳转的.

具体的参数看实际调用:

    func (q *Deque) PushBack(elem interface{}) {
      q.growIfFull()

      q.buf[q.tail] = elem
      q.tail = q.next(q.tail)
      q.count++
    }

这是在尾部追加,PushFront/PopBack/PopFront都是类似处理.

- tail 指向的是最后一个元素后面的位置
- head 指向的是头部元素

Pop还有一个特点:如果环队空了,再执行pop会报异常,
所以在调用方需要在pop之前先做判断.
Front取头元素,Back取尾元素,也有类似的约定.
At获取指定元素,Set变更指定元素,也有类似的约定.

    func (q *Deque) Clear() {
      modBits := len(q.buf) - 1
      for h := q.head; h != q.tail; h = (h + 1) & modBits {
        q.buf[h] = nil
      }
      q.head = 0
      q.tail = 0
      q.count = 0
    }

Clear是清除环队中的元素,同样使用了取模计算.

    // rotate是旋转,有时只是旋转部分,还分方向
    func (q *Deque) Rotate(n int) {
      if q.count <= 1 {
        return
      }

      // 用%操作来计算旋转的长度
      // %被称为取模操作,每个语言的定义都不一样
      // Go中成%为整数相除的余数,有正有负,符合和被除数一致
      n %= q.count
      if n == 0 {
        return
      }

      // 最简单的情况,缓冲满,只需要移动head和tail即可
      modBits := len(q.buf) - 1
      if q.head == q.tail {
        q.head = (q.head + n) & modBits
        q.tail = (q.tail + n) & modBits
        return
      }

      // 缓冲不满,n为负,将尾部移到头部
      if n < 0 {
        for ; n < 0; n++ {
          // Calculate new head and tail using bitwise modulus.
          q.head = (q.head - 1) & modBits
          q.tail = (q.tail - 1) & modBits
          // Put tail value at head and remove value at tail.
          q.buf[q.head] = q.buf[q.tail]
          q.buf[q.tail] = nil
        }
        return
      }

      // 缓冲不满,n为正,将头部移到尾部
      for ; n > 0; n-- {
        // Put head value at tail and remove value at head.
        q.buf[q.tail] = q.buf[q.head]
        q.buf[q.head] = nil
        // Calculate new head and tail using bitwise modulus.
        q.head = (q.head + 1) & modBits
        q.tail = (q.tail + 1) & modBits
      }
    }

在Rotate中,可以将一些计算head和tail的计算替换成next和prev.

    func (q *Deque) SetMinCapacity(minCapacityExp uint) {
      if 1<<minCapacityExp > minCapacity {
        q.minCap = 1 << minCapacityExp
      } else {
        q.minCap = minCapacity
      }
    }

设置最小环队容量,不小于16
