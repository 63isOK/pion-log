# vp8对rtp编码的支持

先了解一下vp8在rtp中的内容:

rtp头分为固定的12字节,外加可选的csrc和扩展,之后就是rtp payload,
如果rtp payload里存的是vp8,那么接下来就是:

- vp8 payload descriptor
- vp8 payload header

先看vp8负载描述:

    /*
     * https://tools.ietf.org/html/rfc7741#section-4.2
     *
     *       0 1 2 3 4 5 6 7
     *      +-+-+-+-+-+-+-+-+
     *      |X|R|N|S|R| PID | (REQUIRED)
     *      +-+-+-+-+-+-+-+-+
     * X:   |I|L|T|K| RSV   | (OPTIONAL)
     *      +-+-+-+-+-+-+-+-+
     * I:   |M| PictureID   | (OPTIONAL)
     *      +-+-+-+-+-+-+-+-+
     * L:   |   TL0PICIDX   | (OPTIONAL)
     *      +-+-+-+-+-+-+-+-+
     * T/K: |TID|Y| KEYIDX  | (OPTIONAL)
     *      +-+-+-+-+-+-+-+-+
     */

第一个字节是必选,后面都是可选,先看第一个字节的意思:

- X, 1表示剩下的可选项是有效的,0表示忽略所有可选项
- R, 保留位
- N, 非引用帧, 1表示丢掉不会影响其他帧,0表示丢弃会影响其他帧
- S, 如果是vp8 partition的开始,设置为1;否则设置为0
- R, 保留位
- PID, partition index,0-7,自增的.

第二个字节,X表示的扩展控制,里面的ILTK就用于控制剩下的可选项,
ILTK分别控制指定功能是否出现,RSV是保留的.

I部分,M表示picture id的位数,M=1表示pictureid为15位;否则就是7位.

L部分,TL0PICIDX表示的是 temportal level zero index,这是1字节的索引,
0-255,vp8/h264在支持svc时,有3方面的扩展:时间(帧率)/空间(分辨率)/质量(码率).
其中时间扩展被分成了4个层T0-T3,也被称为L0-L3,L0是最底层,上层依赖下层.
而这个层,就是下个字节中TID指明的.
当TID大于0时,TL0PICIDX表明当前图像依赖哪层;
当TID为0时,TL0PICIDX要自增.

TK部分,TID表明了当前图像处于哪层,为0表示处于L0,最底层.
Y,1位,为1表示当前图像直接依赖L0,为0表示不依赖L0,此时TL0PICIDX表明了依赖层.
KEYIDX是关键字索引,5位,0-31,如果是新的关键帧,那么索引加1,否则这个索引不变化.

vp8负载头:

关键帧占10字节,非关键字占3字节,其中前3个字节都是公用的.

从rfc上,payload header是属于payload的一部分,所以在rtp层次的分包和解包中,
不会涉及对vp8 payload header的处理.

## 分包,vp8 payload转rtp payload

vp8中的分包切片逻辑:

    type VP8Payloader struct{}

    func (p *VP8Payloader) Payload(mtu int, payload []byte) [][]byte {
      maxFragmentSize := mtu - vp8HeaderSize

      payloadData := payload
      payloadDataRemaining := len(payload)

      payloadDataIndex := 0
      var payloads [][]byte

      // Make sure the fragment/payload size is correct
      if min(maxFragmentSize, payloadDataRemaining) <= 0 {
        return payloads
      }
      for payloadDataRemaining > 0 {
        currentFragmentSize := min(maxFragmentSize, payloadDataRemaining)
        out := make([]byte, vp8HeaderSize+currentFragmentSize)

        // 切片逻辑非常暴力简单: vp8负载描述直接设为了0x10
        // 0x10只设置了S标识,其他的全为0,表示不启用可选项
        // S标识表示这是vp8 payload的开始部分
        if payloadDataRemaining == len(payload) {
          out[0] = 0x10
        }

        copy(out[vp8HeaderSize:], payloadData[payloadDataIndex:payloadDataIndex+currentFragmentSize])
        payloads = append(payloads, out)

        payloadDataRemaining -= currentFragmentSize
        payloadDataIndex += currentFragmentSize
      }

      return payloads
    }

相对于h264的复杂NALU类型来说,vp8的切片逻辑还是比较简单的.

## 解包, rtp payload转vp8 payload

实现rtp解包的类型是VP8Packet:

    type VP8Packet struct {
      // Required Header
      X   uint8 /* extended controlbits present */
      N   uint8
      S   uint8 /* start of VP8 partition */
      PID uint8 /* partition index */

      // Optional Header
      I         uint8  /* 1 if PictureID is present */
      L         uint8  /* 1 if TL0PICIDX is present */
      T         uint8  /* 1 if TID is present */
      K         uint8  /* 1 if KEYIDX is present */
      PictureID uint16 /* 8 or 16 bits, picture ID */
      TL0PICIDX uint8  /* 8 bits temporal level zero index */

      Payload []byte
    }

    func (p *VP8Packet) Unmarshal(payload []byte) ([]byte, error) {
      if payload == nil {
        return nil, errNilPacket
      }

      payloadLen := len(payload)

      if payloadLen < 4 {
        return nil, errShortPacket
      }

      payloadIndex := 0

      p.X = (payload[payloadIndex] & 0x80) >> 7
      p.N = (payload[payloadIndex] & 0x20) >> 5
      p.S = (payload[payloadIndex] & 0x10) >> 4
      p.PID = payload[payloadIndex] & 0x07

      payloadIndex++

      if p.X == 1 {
        p.I = (payload[payloadIndex] & 0x80) >> 7
        p.L = (payload[payloadIndex] & 0x40) >> 6
        p.T = (payload[payloadIndex] & 0x20) >> 5
        p.K = (payload[payloadIndex] & 0x10) >> 4
        payloadIndex++
      }

      if p.I == 1 { // PID present?
        if payload[payloadIndex]&0x80 > 0 { // M == 1, PID is 16bit
          payloadIndex += 2
        } else {
          payloadIndex++
        }
      }

      if p.L == 1 {
        payloadIndex++
      }

      if p.T == 1 || p.K == 1 {
        payloadIndex++
      }

      if payloadIndex >= payloadLen {
        return nil, errShortPacket
      }
      p.Payload = payload[payloadIndex:]
      return p.Payload, nil
    }

整个vp8 rtp的解包,仅仅只是将vp8的payload提取出来.
而h264的fu-a的解包,如果整个NALU包没有提取出来,则会缓存,直到整个NALU完整了再返回,
而vp8的处理,简单了很多,可能跟没有各种NALU类型相关.
