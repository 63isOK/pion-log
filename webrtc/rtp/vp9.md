# vp9对rtp编码的支持

和vp8类似,vp9在rtp头之后,有以下内容:

- vp9 paylaod descriptor
- vp9 paylaod header
- vp9 payload data

如果和vp8类似,那么只用分析到负载描述符

    /*
     * https://www.ietf.org/id/draft-ietf-payload-vp9-10.txt
     *
     * Flexible mode (F=1)
     *        0 1 2 3 4 5 6 7
     *       +-+-+-+-+-+-+-+-+
     *       |I|P|L|F|B|E|V|-| (REQUIRED)
     *       +-+-+-+-+-+-+-+-+
     *  I:   |M| PICTURE ID  | (REQUIRED)
     *       +-+-+-+-+-+-+-+-+
     *  M:   | EXTENDED PID  | (RECOMMENDED)
     *       +-+-+-+-+-+-+-+-+
     *  L:   | TID |U| SID |D| (CONDITIONALLY RECOMMENDED)
     *       +-+-+-+-+-+-+-+-+                             -\
     *  P,F: | P_DIFF      |N| (CONDITIONALLY REQUIRED)    - up to 3 times
     *       +-+-+-+-+-+-+-+-+                             -/
     *  V:   | SS            |
     *       | ..            |
     *       +-+-+-+-+-+-+-+-+
     *
     * Non-flexible mode (F=0)
     *        0 1 2 3 4 5 6 7
     *       +-+-+-+-+-+-+-+-+
     *       |I|P|L|F|B|E|V|-| (REQUIRED)
     *       +-+-+-+-+-+-+-+-+
     *  I:   |M| PICTURE ID  | (RECOMMENDED)
     *       +-+-+-+-+-+-+-+-+
     *  M:   | EXTENDED PID  | (RECOMMENDED)
     *       +-+-+-+-+-+-+-+-+
     *  L:   | TID |U| SID |D| (CONDITIONALLY RECOMMENDED)
     *       +-+-+-+-+-+-+-+-+
     *       |   TL0PICIDX   | (CONDITIONALLY REQUIRED)
     *       +-+-+-+-+-+-+-+-+
     *  V:   | SS            |
     *       | ..            |
     *       +-+-+-+-+-+-+-+-+
     */

通过第一个字节的F标识,来确定了两种模式.先分析第一个字节:

- I, 是否显示picture id
- P, 是否是p帧
- L, 是否显示层索引,这个类似vp8的L0-L3,以及TL0PICIDX
- F, 是否是灵活模式,如果I设置为1,则F为1;I设置为0,F为0.F只影响关键帧的第一个包
- B, 是否是vp9帧的开头,1是0不是
- E, 是否是vp9帧的结尾
- V, 是否带ss信息.ss信息是空间可适应信息,也就是分辨率缩放的支持信息
- Z, 不是一个更大空间的参考帧,1表示更大空间的和后续图像不会参考本帧

如果说L是的帧率之间的L0-L3的关系,那么V和Z就是分辨率之间的一些关系.

之后一个字节,也就是I部分,M表示PID是15位还是7位.

L部分,指明了TID和SID,分别对应时域/空域的L0-L3,
U表示当前层帧是否依赖同一时间层的先前层帧.
D表示当前层帧是否依赖当前超级帧内靠前的一个空间层帧.

P,F标识,当p和f都为1(表明是p帧,也是flexible模式),
vp9中,p帧可以参考3个帧,`P_DIFF`指明向前参考第几个帧,
N表示,`P_DIFF`后面是否追加一个新的`P_DIFF`.

最后是scalability structure,可伸缩结构ss.

    // Scalability structure (SS):
    //
    //      +-+-+-+-+-+-+-+-+
    // V:   | N_S |Y|G|-|-|-|
    //      +-+-+-+-+-+-+-+-+              -|
    // Y:   |     WIDTH     | (OPTIONAL)    .
    //      +               +               .
    //      |               | (OPTIONAL)    .
    //      +-+-+-+-+-+-+-+-+               . N_S + 1 times
    //      |     HEIGHT    | (OPTIONAL)    .
    //      +               +               .
    //      |               | (OPTIONAL)    .
    //      +-+-+-+-+-+-+-+-+              -|
    // G:   |      N_G      | (OPTIONAL)
    //      +-+-+-+-+-+-+-+-+                           -|
    // N_G: |  T  |U| R |-|-| (OPTIONAL)                 .
    //      +-+-+-+-+-+-+-+-+              -|            . N_G times
    //      |    P_DIFF     | (OPTIONAL)    . R times    .
    //      +-+-+-+-+-+-+-+-+              -|           -|

SS描述了图片每帧的分辨率以及图片组PG内部图片之间的关系.
vp9负载描述的第一个字节设置了V,就会有SS信息.

SS第一个字节说明:

`N_S`+1,表示vp9流中空域分层的层数,也就是支持的分辨率个数.
Y表示是否显示层帧的分辨率.
G表示是否显示描述图片组PG的标识.

分辨率的宽高都是用2个字节来显示,宽高可显示多个,有几个分辨率显示几个.

`N_G`,是图片组PG中图片的数量,大于1表示vp9流中启用了图片间的相关性,
等于0表示每个图片都是独立的.大于0时,会携带TID/U/`P_DIFFS`信息.
图片组PG中第一个图片的TID需要设置为0,因为她不需要参考之前的图片.

## vp9 payload在rtp分包器中的切片逻辑

vp9的切片逻辑比vp8复杂不少:

    type VP9Payloader struct {
      pictureID   uint16
      initialized bool

      InitialPictureIDFn func() uint16
    }

    func (p *VP9Payloader) Payload(mtu int, payload []byte) [][]byte {

      // 初始化,设定初始的picture id的值,随机的,15位
      if !p.initialized {
        if p.InitialPictureIDFn == nil {
          p.InitialPictureIDFn = func() uint16 {
            return uint16(globalMathRandomGenerator.Intn(0x7FFF))
          }
        }
        p.pictureID = p.InitialPictureIDFn() & 0x7FFF
        p.initialized = true
      }

      if payload == nil {
        return [][]byte{}
      }

      // 这里的vp9头,规定的是3字节,其实指的是vp 负载描述的前3字节
      maxFragmentSize := mtu - vp9HeaderSize
      payloadDataRemaining := len(payload)
      payloadDataIndex := 0

      if min(maxFragmentSize, payloadDataRemaining) <= 0 {
        return [][]byte{}
      }

      var payloads [][]byte
      for payloadDataRemaining > 0 {
        currentFragmentSize := min(maxFragmentSize, payloadDataRemaining)
        out := make([]byte, vp9HeaderSize+currentFragmentSize)

        // 只设置了带pid,并设置了vp9 payload的开头(B)
        out[0] = 0x90 // F=1 I=1
        if payloadDataIndex == 0 {
          out[0] |= 0x08 // B=1
        }

        // 如果是vp9 payload 结尾,设置E
        if payloadDataRemaining == currentFragmentSize {
          out[0] |= 0x04 // E=1
        }
        out[1] = byte(p.pictureID>>8) | 0x80
        out[2] = byte(p.pictureID)
        copy(out[vp9HeaderSize:], payload[payloadDataIndex:payloadDataIndex+currentFragmentSize])
        payloads = append(payloads, out)

        payloadDataRemaining -= currentFragmentSize
        payloadDataIndex += currentFragmentSize
      }

      // 更新pid,15位,不能超过0x8000
      p.pictureID++
      if p.pictureID >= 0x8000 {
        p.pictureID = 0
      }

      return payloads
    }

整体上看,vp9在rtp分包切片时的逻辑并不复杂.

## rtp paylaod解包为vp9 payload

    type VP9Packet struct {
      I bool // PictureID is present
      P bool // Inter-picture predicted frame
      L bool // Layer indices is present
      F bool // Flexible mode
      B bool // Start of a frame
      E bool // End of a frame
      V bool // Scalability structure (SS) data present

      PictureID uint16 // 7 or 16 bits, picture ID

      TID uint8 // Temporal layer ID
      U   bool  // Switching up point
      SID uint8 // Spatial layer ID
      D   bool  // Inter-layer dependency used

      PDiff     []uint8 // Reference index (F=1)
      TL0PICIDX uint8   // Temporal layer zero index (F=0)

      NS      uint8 // N_S + 1 indicates the number of spatial layers present
                    // in the VP9 stream
      Y       bool  // Each spatial layer's frame resolution present
      G       bool  // PG description present flag.
      NG      uint8 // N_G indicates the number of pictures in a Picture Group (PG)
      Width   []uint16
      Height  []uint16
      PGTID   []uint8   // Temporal layer ID of pictures in a Picture Group
      PGU     []bool    // Switching up point of pictures in a Picture Group
      PGPDiff [][]uint8 // Reference indecies of pictures in a Picture Group

      Payload []byte
    }

因为是rtp解包,所以会按标准的来,但这个解包只是为了解出vp9 payload,
所以并不关心这中间参数.

具体的解包过程就不贴了.

最后还是提供了关键帧的检查:

    type VP9PartitionHeadChecker struct{}

    func (*VP9PartitionHeadChecker) IsPartitionHead(packet []byte) bool {
      p := &VP9Packet{}
      if _, err := p.Unmarshal(packet); err != nil {
        return false
      }
      return p.B
    }
