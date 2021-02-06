# RTCPReader

先看类型定义:

		type RTCPReader struct {
			ssrc     uint32
			closed   atomicBool
			onPacket func([]byte)
			onClose  func()
		}

		func NewRTCPReader(ssrc uint32) *RTCPReader {
			return &RTCPReader{ssrc: ssrc}
		}

在分析之前先看atomicBool

		type atomicBool int32

		func (a *atomicBool) set(value bool) {
			var i int32
			if value {
				i = 1
			}
			atomic.StoreInt32((*int32)(a), i)
		}

		func (a *atomicBool) get() bool {
			return atomic.LoadInt32((*int32)(a)) != 0
		}

这个atomicBool就是利用atomic来实现的,将对bool变量的原子操作,
用int32变量的原子操作来代替.

RTCPReader有两个函数变量:

		func (r *RTCPReader) OnClose(fn func()) {
			r.onClose = fn
		}

		func (r *RTCPReader) OnPacket(f func([]byte)) {
			r.onPacket = f
		}

在主动调用RTCPReader.Close()时会触发关闭回调:

		func (r *RTCPReader) OnClose(fn func()) {
			r.onClose = fn
		}

在调用Write时会触发onPacket回调:

		func (r *RTCPReader) Write(p []byte) (n int, err error) {
			if r.closed.get() {
				err = io.EOF
				return
			}
			if r.onPacket != nil {
				r.onPacket(p)
			}
			return
		}

最后还定义了Read,里面是空逻辑:

		func (r *RTCPReader) Read(_ []byte) (n int, err error) { return }

## 总结

这个RTCPReader并不带逻辑,仅仅在调用方和被调用方之间插了一个中间层,
这是为了扩展的考虑,将上下进行分离.

而ssrc字段,应该是用于RTCPReader实例的区分.
