# bucket

结构分析:

Bucket是结构, NewBucket是构造,其他都是非对暴露的.

其他内部功能函数 get/set是为addPacket/getPacket/push提供功能.

		type Bucket struct {
			buf    []byte
			nacker *nackQueue

			headSN   uint16
			step     int
			maxSteps int

			onLost func(nack []rtcp.NackPair, askKeyframe bool)
		}

从后面的分析也可以看出,buf里存放的是rtp包的数据.

		func NewBucket(buf []byte, nack bool) *Bucket {
			b := &Bucket{
				buf:      buf,
				maxSteps: int(math.Floor(float64(len(buf))/float64(maxPktSize))) - 1,
			}
			if nack {
				b.nacker = newNACKQueue()
			}
			return b
		}

这个构造里也非常有意思:
step表示此桶Bucket放了多少rtp包,maxSteps表示最多可以放多少rtp包,
step只在每次push包时增加,最有趣的时step和maxSteps都是以索引方式表示.
再回头看构造时的默认处理: maxSteps有各减1操作,step直接初始化为0,
真是精致.

		func (b *Bucket) push(pkt []byte) []byte {
			binary.BigEndian.PutUint16(b.buf[b.step*maxPktSize:], uint16(len(pkt)))
			off := b.step*maxPktSize + 2
			copy(b.buf[off:], pkt)
			b.step++
			if b.step >= b.maxSteps {
				b.step = 0
			}
			return b.buf[off : off+len(pkt)]
		}

从这里可以看出,缓冲Bucket.buf是被分成了几段,每一段都足够放一个rtp包,
每段的存储方式是:前两字节存rtp包的长度,之后才是rtp包的数据.
一旦所有的段都存放了,step就会重置,下一次push就会替换第一各段.
有点"元素固定长度+环队"的意思.
push中还有一个点:step指向的是下一个rtp包要放的位置:push中是先拷贝后自增的.

push返回的是缓冲中,rtp包数据.

		func (b *Bucket) set(sn uint16, pkt []byte) []byte {

			// 这一小段需要单独说一下:
			// step是自己维护的环队
			// rtp是按sn连续地摆在这个环队中
			// 如果有丢失,step也会自增
			// step指向的是headSN的下一个环队段索引
			// 所以在计算pos时,step-1表示headSN的索引,之后在计算sn的偏移
			pos := b.step - int(b.headSN-sn+1)
			if pos < 0 {
				// maxSteps也是一个索引,所以maxSteps+1才是真的段数量
				// 这里的+1和计算pos是的+1并不是同一个逻辑
				pos = b.maxSteps + pos + 1
			}

			off := pos * maxPktSize

			// 保证不set的sn在一定范围内
			// get()函数使用另一种方式在实现
			if off > len(b.buf) || off < 0 {
				return nil
			}
			binary.BigEndian.PutUint16(b.buf[off:], uint16(len(pkt)))
			copy(b.buf[off+2:], pkt)
			return b.buf[off+2 : off+2+len(pkt)]
		}

set是直接在缓冲中替换一个rtp的数据:

headSN表示最近添加到缓冲中的rtp包sn号,在获取环队的段地址时,
非常有意思,具体可以看上面的注释.

另外,对与同一个逻辑,在不同地方,开源贡献者都在秀她的技术.
开源就是程序员自己表达自己,宣泄自己的地方.

set里的具体逻辑还是前2字节放长度,后面跟rtp包数据.

		func (b *Bucket) addPacket(pkt []byte, sn uint16, latest bool) []byte {

			// 如果是前面的rtp包
			if !latest {
				if b.nacker != nil {
					b.nacker.remove(sn)
				}
				return b.set(sn, pkt)
			}

			// 如果是后面的rtp包
			diff := sn - b.headSN
			b.headSN = sn
			for i := uint16(1); i < diff; i++ {

				// 中间缺失都被认为是丢失的
				b.step++
				if b.nacker != nil {
					b.nacker.push(sn - i)
				}
				if b.step >= b.maxSteps {
					b.step = 0
				}
			}

			// 每次处理rtp包,都触发onLost处理
			if b.nacker != nil {
				np, akf := b.nacker.pairs()
				if len(np) > 0 {
					b.onLost(np, akf)
				}
			}
			return b.push(pkt)
		}

addPacket里面封装了几个逻辑:

- rtp包的乱序处理,新包用push,其他用set
- 新包到上次标记的最大包之间的,全部视为丢包
- 每次处理rtp包,都会触发对丢包的处理

看完了添加,再看看获取:

		func (b *Bucket) get(sn uint16) []byte {
			pos := b.step - int(b.headSN-sn+1)
			if pos < 0 {
				if pos*-1 > b.maxSteps {
					return nil
				}
				pos = b.maxSteps + pos + 1
			}
			off := pos * maxPktSize
			if off > len(b.buf) {
				return nil
			}
			if binary.BigEndian.Uint16(b.buf[off+4:off+6]) != sn {
				return nil
			}
			sz := int(binary.BigEndian.Uint16(b.buf[off : off+2]))
			return b.buf[off+2 : off+2+sz]
		}

在get中,sn首先要转换成环队的具体段,也就是上面的pos,
rtp包的2-4字节是序号.需要澄清一点:rtp的序号是16位,rtcp的序号是15位.
在get中还会验证序号sn是否正确,之后再去rtp包数据.

		func (b *Bucket) getPacket(buf []byte, sn uint16) (i int, err error) {
			p := b.get(sn)
			if p == nil {
				err = errPacketNotFound
				return
			}
			i = len(p)
			if cap(buf) < i {
				err = errBufferTooSmall
				return
			}
			if len(buf) < i {
				buf = buf[:i]
			}
			copy(buf, p)
			return
		}

getPacket仅仅是将get出来的拷贝到一个缓冲.

## 总结

总体来说,Bucket使用环队来存rtp包数据,使用nackQueue来维护丢包队列.
对外提供的功能函数是addPacket/getPacket,分别用于读和写.

最后的扩展时对nack队列的处理onLost.这个在Buffer中有,到时候再分析这个.
