# pion/rtp包

这个包的作用是对rtp的分包和组包

## packetize 分包

分包对象Packetizer

    type Packetizer interface {
      Packetize(payload []byte, samples uint32) []*Packet
      EnableAbsSendTime(value int)
    }

分包器Packetizer主要的作用就是将payload切成做个rtp包,
也就是rtp.Packet.

    type packetizer struct {
      MTU              int
      PayloadType      uint8
      SSRC             uint32
      Payloader        Payloader
      Sequencer        Sequencer
      Timestamp        uint32
      ClockRate        uint32
      extensionNumbers struct {
        AbsSendTime int
      }
      timegen func() time.Time
    }

packetizer是分包器的具体实现.

    func NewPacketizer(mtu int, pt uint8, ssrc uint32,
      payloader Payloader, sequencer Sequencer, clockRate uint32) Packetizer {

      return &packetizer{
        MTU:         mtu,
        PayloadType: pt,
        SSRC:        ssrc,
        Payloader:   payloader,
        Sequencer:   sequencer,
        Timestamp:   globalMathRandomGenerator.Uint32(),
        ClockRate:   clockRate,
        timegen:     time.Now,
      }
    }

分包器的构造非常简单,mtu/payloadtype/ssrc/时钟频率都有提供,
对于Payloader/Sequencer接口都由构造参数指定.
时间戳timestamp由随机数指定,事件获取函数指定为time.Now.

    func (p *packetizer) EnableAbsSendTime(value int) {
      p.extensionNumbers.AbsSendTime = value
    }

这个方法仅仅是设置abs-send-time的属性.

    func (p *packetizer) Packetize(payload []byte, samples uint32) []*Packet {
      // 过滤掉payload为空的情况
      if len(payload) == 0 {
        return nil
      }

      // 将payload按mtu-12进行切分成多个小片
      // 首先mtu-12的原因,12是指前12个字节,
      // 这里是rtp包将payload切成rtp包,并没有处理csrc等信息
      payloads := p.Payloader.Payload(p.MTU-12, payload)
      packets := make([]*Packet, len(payloads))

      for i, pp := range payloads {

        //可以看出rtp头中很多信息都是固定的
        packets[i] = &Packet{
          Header: Header{
            Version:        2,
            Padding:        false,
            Extension:      false,
            Marker:         i == len(payloads)-1,
            PayloadType:    p.PayloadType,
            SequenceNumber: p.Sequencer.NextSequenceNumber(),
            Timestamp:      p.Timestamp,
            SSRC:           p.SSRC,
          },
          Payload: pp,
        }
      }
      p.Timestamp += samples

      // 下面是支持abs-send-time扩展
      // 等会单独用章节来分析
      if len(packets) != 0 && p.extensionNumbers.AbsSendTime != 0 {
        sendTime := NewAbsSendTimeExtension(p.timegen())
        // apply http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time
        b, err := sendTime.Marshal()
        if err != nil {
          return nil // never happens
        }
        err = packets[len(packets)-1].SetExtension(
          uint8(p.extensionNumbers.AbsSendTime), b)

        if err != nil {
          return nil // never happens
        }
      }

      return packets
    }

整个分包器分包的逻辑都在Packetize方法上.
具体的流程分析直接写在上面的代码上了.

先来分析abs-send-time,再来总结分包器.
