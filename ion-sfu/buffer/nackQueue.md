# buffer.nackQueue类型

nack是负反馈,是接收方通知发送方,哪些包丢了.

    type nack struct {
      sn     uint32
      nacked uint8
    }

    type nackQueue struct {
      nacks   []nack
      counter uint8
      maxSN   uint16
      kfSN    uint32
      cycles  uint32
    }

    func newNACKQueue() *nackQueue {
      return &nackQueue{
        nacks:  make([]nack, 0, maxNackCache+1),
        maxSN:  0,
        cycles: 0,
      }
    }

队列/元素/构造.

整个队列的容量是101.

push是入队:

    // 这个类型可能需要结合使用场景来理解
    // 0x8000 vp9编码中的序号占7位,扩展位8位
    // 所以pid的范围是0-0x7fff, 这样pid永远不会超过0x8000
    // pid一旦达到0x8000,就会自动转为0
    // 需要注意的是:上面说的是rtp包中的序号,而我们这里的sn不一样
    // 这里的sn号是包含pid前面的一个标识位M,M=1表示pid有扩展的8位,
    // M=0表示pid没有扩展位,现在M默认指定为1
    // pid是15位, sn是包含了M位的16位 = pid + 1000 0000 0000 0000
    func (n *nackQueue) push(sn uint16) {
      var extSN uint32

      // 更新队列中维护的最大sn
      if n.maxSN == 0 {
        n.maxSN = sn
      } else if (sn-n.maxSN)&0x8000 == 0 {

        // 一旦发生了pid重置,用cycles来记录总的重置数
        // pid是随机初始的一个值,在0-7fff之间
        // 之后每次自增1
        // 所以 (sn-n.maxSN)永远都不会超过0x8000,
        // 但是,因为语言机制,uint16表示的范围有限,-1会用ffff来表示
        // 那么这个条件分支,只要sn小于n.maxSN,她们的差值就是负数,与上0x8000就为真了
        // 所以这个分支的逻辑意义是:
        // 收到一个nack信息,这个nack的sn比之前维护的更大,就更新维护的最大sn号
        // 

        // sn 小于n.maxSN, 只会出现在在pid重置一次了
        // 此时sn为0
        if sn < n.maxSN {
          n.cycles += maxSN
        }

        // maxSN跟着sn走,直到sn重新出现重置
        n.maxSN = sn
      }

      if sn > n.maxSN && sn&0x8000 == 1 && n.maxSN&0x8000 == 0 {
        extSN = (n.cycles - maxSN) | uint32(sn)
      } else {
        extSN = n.cycles | uint32(sn)
      }

      i := sort.Search(len(n.nacks),
        func(i int) bool { return n.nacks[i].sn >= extSN })
      if i < len(n.nacks) && n.nacks[i].sn == extSN {
        return
      }
      n.nacks = append(n.nacks, nack{})
      copy(n.nacks[i+1:], n.nacks[i:])
      n.nacks[i] = nack{
        sn:     extSN,
        nacked: 0,
      }

      if len(n.nacks) > maxNackCache {
        n.nacks = n.nacks[1:]
      }
      n.counter++
    }

