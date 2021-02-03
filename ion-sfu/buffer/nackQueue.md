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
    //
    // 再次确认:
    // rtp里的packet id,现在大多指定为15位,并不仅仅是vp9才这样.
    func (n *nackQueue) push(sn uint16) {
      var extSN uint32

      // 更新队列中维护的最大sn
      // 这个maxSN的初始化只会触发一次
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
        // 收到一个nack,如果如果sn大,就更新最大的maxSN
        // 如果收到的nack的pid比较小,就不会进入这个分支

        if sn < n.maxSN {
          n.cycles += maxSN
        }

        // sn重置,才会更新maxSN
        n.maxSN = sn
      }

      //
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

`重要提示:sn的理解可能有误,一直以为sn在0x8000到0xffff之间,
作者解释sn可以小于0x8000.所以还需要查一下.`

再重新看下这个nackQueue的push:

- 当sn发生重置时,会更新cycles
- 每次都会根据sn和cycles计算一个逻辑上的sn号(就是不发生重置的sn)
- 根据extSN来决定每个nack包在nackQueue中的位置

和push对应的是remove:

    func (n *nackQueue) remove(sn uint16) {
      var extSN uint32
      if sn > n.maxSN && sn&0x8000 == 1 && n.maxSN&0x8000 == 0 {
        extSN = (n.cycles - maxSN) | uint32(sn)
      } else {
        extSN = n.cycles | uint32(sn)
      }

      i := sort.Search(len(n.nacks), func(i int) bool {
        return n.nacks[i].sn >= extSN })
      if i >= len(n.nacks) || n.nacks[i].sn != extSN {
        return
      }
      copy(n.nacks[i:], n.nacks[i+1:])
      n.nacks = n.nacks[:len(n.nacks)-1]
    }

也是根据输入的sn来计算逻辑上的sn号,再从丢包队列nackQueue中移除.

这个nack.go后续还需要再看看.看看调用和整体上的逻辑.

这个nackQueue.pairs很有意思.
rtcp的tln类型包中,tln的fci就是一个个NackPair,
而pairs()就是将nack队列全部转换成NackPair.
过程也很有意思:

    func (n *nackQueue) pairs() ([]rtcp.NackPair, bool) {
      if n.counter < 2 {
        n.counter++
        return nil, false
      }
      n.counter = 0
      i := 0
      askKF := false
      var np rtcp.NackPair
      var nps []rtcp.NackPair
      for _, nck := range n.nacks {

        // 如果某个包标记为丢失已经3次了,则发送pli,要求一个关键帧
        if nck.nacked >= maxNackTimes {
          if nck.sn > n.kfSN {
            n.kfSN = nck.sn
            askKF = true
          }
          continue
        }

        // 重排nackQueue,并更新标记次数
        n.nacks[i] = nack{
          sn:     nck.sn,
          nacked: nck.nacked + 1,
        }
        i++

        // 一个个NackPair来处理
        if np.PacketID == 0 || uint16(nck.sn) > np.PacketID+16 {
          if np.PacketID != 0 {
            nps = append(nps, np)
          }
          np.PacketID = uint16(nck.sn)
          np.LostPackets = 0
          continue
        }
        np.LostPackets |= 1 << (uint16(nck.sn) - np.PacketID - 1)
      }
      if np.PacketID != 0 {
        nps = append(nps, np)
      }

      // 最后更新nackQueue的长度
      n.nacks = n.nacks[:i]
      return nps, askKF
    }

## 总结

nackQueue提供了3个方法,入队/出队/转换成tln的NackPair.

除了对sn号的理解还不足以外,其他部分都非常明确.
