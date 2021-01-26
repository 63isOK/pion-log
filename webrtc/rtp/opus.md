# opus对rtp的编码支持

## rtp分包时的切片逻辑

音频数据比较小,一份音频数据只会分成一个rtp包

    func (p *OpusPayloader) Payload(mtu int, payload []byte) [][]byte {
      if payload == nil {
        return [][]byte{}
      }

      out := make([]byte, len(payload))
      copy(out, payload)
      return [][]byte{out}
    }

## 解包时的实现

因为分包逻辑简单,所以解包同样简单

    type OpusPacket struct {
      Payload []byte
    }

    func (p *OpusPacket) Unmarshal(packet []byte) ([]byte, error) {
      if packet == nil {
        return nil, errNilPacket
      } else if len(packet) == 0 {
        return nil, errShortPacket
      }

      p.Payload = packet
      return packet, nil
    }

opus payload 在转成rtp payload时,并没有任何添加字节或减少字节.
解包失败的条件是入参`[]byte`要么没有初始化,要么长度为0.

关键帧监测:

    type OpusPartitionHeadChecker struct{}

    func (*OpusPartitionHeadChecker) IsPartitionHead(packet []byte) bool {
      p := &OpusPacket{}
      if _, err := p.Unmarshal(packet); err != nil {
        return false
      }
      return true
    }
