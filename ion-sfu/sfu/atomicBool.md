# atomicBool类型

这是一个未暴露的类型,只在包内使用

    type atomicBool struct {
      val int32
    }

    func (b *atomicBool) set(value bool) { // nolint: unparam
      var i int32
      if value {
        i = 1
      }

      atomic.StoreInt32(&(b.val), i)
    }

    func (b *atomicBool) get() bool {
      return atomic.LoadInt32(&(b.val)) != 0
    }

sync/atomic提供了一些内存原语,是非常底层的同步原语.

Loadxxx是从内存地址取数据,Storexxx是存数据到指定内存.

atomicBool.set()利用参数来控制局部变量i的零值,
从而给atomicBool.val设置0或1,get()就是判断是否是0.

利用sync/atomic包,实现了一个并发安全的bool型对象.

