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

### abs-send-time支持

rtp头上有个字段X表示在csrc后面是否扩展段,当X=1时,在csrc后有扩展段,
这块的内容是在rfc3550上定义的.

rfc3550上没有定义扩展段是如何使用的,这在rfc5285定义的.
abs-send-time就是使用rfc5285中的one-byte模式去填充的.
需要注意:abs-send-time是webrtc定义的,只是使用了rfc5285的填充格式.

abs-send-time:

- 1字节的扩展,3字节的数据,共4个字节,如果算上rfc5285的填充头,还要4字节
- 这个时间是给remb算法去计算的拥塞控制的
- 至少有18位的浮点,6位的整数,uint64的精度是3.8us
- abs-send-time的单位是秒,常用24位来表示
  - `abs_send_time_24 = (ntp_timestamp_64>>14) & 0x00FFFFFF`
  - ntp 时间戳是64位, 高32表示秒, 低32位表示小数部分

下面是abs-send-time对应的类型

    type AbsSendTimeExtension struct {
      Timestamp uint64
    }

    // 虽然uint64是8字节,但abs-send-time实际内容只有3字节
    func (t *AbsSendTimeExtension) Marshal() ([]byte, error) {
      return []byte{
        byte(t.Timestamp & 0xFF0000 >> 16),
        byte(t.Timestamp & 0xFF00 >> 8),
        byte(t.Timestamp & 0xFF),
      }, nil
    }

    func (t *AbsSendTimeExtension) Unmarshal(rawData []byte) error {
      if len(rawData) < absSendTimeExtensionSize {
        return errTooSmall
      }
      t.Timestamp = uint64(rawData[0])<<16 | uint64(rawData[1])<<8 | uint64(rawData[2])
      return nil
    }

这是abs-send-time的定义和序列化.

    func NewAbsSendTimeExtension(sendTime time.Time) *AbsSendTimeExtension {
      return &AbsSendTimeExtension{
        Timestamp: toNtpTime(sendTime) >> 14,
      }
    }

`>> 14`,是因为只关心18位小数(18=32-14)

这个构造只会在分包器的分包逻辑中才会用到:

    sendTime := NewAbsSendTimeExtension(p.timegen())

构造参数是time.Now,在构造函数内部还对发送时间sendTime做了一些处理:

    func toNtpTime(t time.Time) uint64 {
      var s uint64
      var f uint64
      u := uint64(t.UnixNano()) // 获取纳秒
      s = u / 1e9 // 获取秒
      s += 0x83AA7E80 // unix时间转ntp时间, 0x83aa7e80就是1970/01/01的秒数
      f = u % 1e9 // 取纳秒,不含秒
      f <<= 32    // 放在uint64的低32位
      f /= 1e9    // 对应着s除以1e9
      s <<= 32    // ntp秒数放在uint64的高32位

      return s | f
    }

    func toTime(t uint64) time.Time {
      s := t >> 32
      f := t & 0xFFFFFFFF
      f *= 1e9
      f >>= 32
      s -= 0x83AA7E80
      u := s*1e9 + f

      return time.Unix(0, int64(u))
    }

这两个功能函数互为逆操作.

    func (t *AbsSendTimeExtension) Estimate(receive time.Time) time.Time {
      receiveNTP := toNtpTime(receive)
      ntp := receiveNTP&0xFFFFFFC000000000 | (t.Timestamp&0xFFFFFF)<<14
      if receiveNTP < ntp {
        // Receive time must be always later than send time
        ntp -= 0x1000000 << 14
      }

      return toTime(ntp)
    }

这个方法是预估,通过接收时间来预估,做法是将abs-send-time的24位(6位秒,18位小数)
代替接收时间的24位,得到一个新的时间,最后会转成一个时间戳.

### 总结分包器

分包器的分包逻辑中,在构造完一个rtp包后,如果存在abs-send-time扩展:

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

这里是调用SetExtension来设置扩展数据.SetExtension在分析rtp Packet时细说.

分包器总结:

- Packetizer分包器接口对外暴露的方法:分包/启用abs-send-time
- 外部扩展有两个:
  - Sequencer,rtp序号生成方式
  - Payloader, payload的具体切分逻辑

其中Payloader在子包实现,由具体的编码来实现.
g711/g722/h264/opus/vp8/vp9.

ps: pion/rtp同样支持了autio level和transport cc两种扩展,但并未应用在代码中,
所以暂不分析.

### 外部扩展 Sequencer

Sequencer是在生成rtp包的过程中,生成其中的rtp序号.

    type Sequencer interface {
      NextSequenceNumber() uint16
      RollOverCount() uint64
    }

通过rfc3550可以查到,rtp的序号占2个字节.
总共也就65536个,所以会有翻转的.

    type sequencer struct {
      sequenceNumber uint16
      rollOverCount  uint64
      mutex          sync.Mutex
    }

    // 输出下一个序号,也考虑到了翻转的情况
    func (s *sequencer) NextSequenceNumber() uint16 {
      s.mutex.Lock()
      defer s.mutex.Unlock()

      s.sequenceNumber++
      if s.sequenceNumber == 0 {
        s.rollOverCount++
      }

      return s.sequenceNumber
    }

    // 获取翻转的次数
    func (s *sequencer) RollOverCount() uint64 {
      s.mutex.Lock()
      defer s.mutex.Unlock()

      return s.rollOverCount
    }

构造函数有两个,以支持不同的场景:

    func NewRandomSequencer() Sequencer {
      return &sequencer{
        sequenceNumber: uint16(globalMathRandomGenerator.Intn(math.MaxUint16)),
      }
    }

    func NewFixedSequencer(s uint16) Sequencer {
      return &sequencer{
        sequenceNumber: s - 1, // -1 because the first sequence number prepends 1
      }
    }

不同的构造函数,只是设置了不同的序号起始值,可以固定;可以随机.

## 解包器 Depacketizer

rtp解包是指将多个rtp包合成一份样本数据.

    type Depacketizer interface {
      Unmarshal(packet []byte) ([]byte, error)
    }

具体的实现在子包pion/rtp/codec中,由具体的编码来实现.
h264/opus/vp8/vp9.

## rtp包 Packet

类型:

    type Packet struct {
      Header
      Raw     []byte
      Payload []byte
    }

头

    type Header struct {
      Version          uint8
      Padding          bool
      Extension        bool
      Marker           bool
      PayloadOffset    int
      PayloadType      uint8
      SequenceNumber   uint16
      Timestamp        uint32
      SSRC             uint32
      CSRC             []uint32
      ExtensionProfile uint16
      Extensions       []Extension
    }

头扩展

    type Extension struct {
      id      uint8
      payload []byte
    }

先看Header的方法

    func (h *Header) MarshalSize() int {

      // 12字节是固定的头
      // 每个csrc是4字节
      size := 12 + (len(h.CSRC) * csrcLength)

      // 如果有扩展
      if h.Extension {
        // 2字节的起始,2字节表示扩展长度
        // one byte以0xbede开头
        // two byte以0x1000开头
        extSize := 4

        switch h.ExtensionProfile {
        case extensionProfileOneByte:
          // one byte 扩展, 1字节+数据长度
          // 1字节内部: 前4位表示id,后4位表示数据长度
          for _, extension := range h.Extensions {
            extSize += 1 + len(extension.payload)
          }
        case extensionProfileTwoByte:
          // two byte 扩展, 2字节+数据长度
          // 2字节内部: 前1字节表示id,后1字节表示数据长度
          for _, extension := range h.Extensions {
            extSize += 2 + len(extension.payload)
          }
        default:
          extSize += len(h.Extensions[0].payload)
        }

        // 4字节对齐
        size += ((extSize + 3) / 4) * 4
      }

      return size
    }

rtp的结构是这样的:

- 固定的12字节的头
- 可选的csrc列表
- 扩展

序列化Marshal内部封装了MarshalTo:

    func (h *Header) MarshalTo(buf []byte) (n int, err error) {
      /*
       *  0                   1                   2                   3
       *  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
       * +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       * |V=2|P|X|  CC   |M|     PT      |       sequence number         |
       * +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       * |                           timestamp                           |
       * +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       * |           synchronization source (SSRC) identifier            |
       * +=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+
       * |            contributing source (CSRC) identifiers             |
       * |                             ....                              |
       * +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       */

      size := h.MarshalSize()
      if size > len(buf) {
        return 0, io.ErrShortBuffer
      }

      // 第一个字节,包含了 version/padding/extension/csrc count
      buf[0] = (h.Version << versionShift) | uint8(len(h.CSRC))
      if h.Padding {
        buf[0] |= 1 << paddingShift
      }

      if h.Extension {
        buf[0] |= 1 << extensionShift
      }

      // 第二个字节,包含marker标记和paylaod类型
      buf[1] = h.PayloadType
      if h.Marker {
        buf[1] |= 1 << markerShift
      }

      // 之后是两字节的序号;4字节的时间戳;4字节的ssrc
      binary.BigEndian.PutUint16(buf[2:4], h.SequenceNumber)
      binary.BigEndian.PutUint32(buf[4:8], h.Timestamp)
      binary.BigEndian.PutUint32(buf[8:12], h.SSRC)

      // csrc是可选,每个csrc是4字节
      n = 12
      for _, csrc := range h.CSRC {
        binary.BigEndian.PutUint32(buf[n:n+4], csrc)
        n += 4
      }

      // csrc之后是扩展,扩展也是可选的
      if h.Extension {
        extHeaderPos := n

        // 写入扩展profile
        binary.BigEndian.PutUint16(buf[n+0:n+2], h.ExtensionProfile)

        // 4表示2字节的扩展profile和2字节的扩展长度
        // 扩展长度的写入在整个扩展写完之后,因为可能有对齐和填充
        n += 4
        startExtensionsPos := n

        switch h.ExtensionProfile {
        case extensionProfileOneByte:

          // 1字节的id/length,后跟数据
          for _, extension := range h.Extensions {
            buf[n] = extension.id<<4 | (uint8(len(extension.payload)) - 1)
            n++
            n += copy(buf[n:], extension.payload)
          }
        case extensionProfileTwoByte:
          // 1字节的id,1字节的length,后跟数据
          for _, extension := range h.Extensions {
            buf[n] = extension.id
            n++
            buf[n] = uint8(len(extension.payload))
            n++
            n += copy(buf[n:], extension.payload)
          }
        default:
          // 3550默认规定的只有一个扩展,长度是4的倍数
          extlen := len(h.Extensions[0].payload)
          if extlen%4 != 0 {
            return 0, io.ErrShortBuffer
          }
          n += copy(buf[n:], h.Extensions[0].payload)
        }

        // 对齐
        extSize := n - startExtensionsPos
        roundedExtSize := ((extSize + 3) / 4) * 4

        // 写扩展长度
        binary.BigEndian.PutUint16(buf[extHeaderPos+2:extHeaderPos+4], uint16(roundedExtSize/4))

        // 如果未对齐,填充
        for i := 0; i < roundedExtSize-extSize; i++ {
          buf[n] = 0
          n++
        }
      }

      h.PayloadOffset = n

      return n, nil
    }

Header的序列化.Header的反序列化UnMarshal是逆操作,就不分析了.

    func (h *Header) SetExtension(id uint8, payload []byte) error {

      // 如果已经有了扩展
      if h.Extension {
        switch h.ExtensionProfile {
        case extensionProfileOneByte:
          // one byte 的id范围是1-14,扩展长度不能超过16字节
          if id < 1 || id > 14 {
            return fmt.Errorf("%w actual(%d)", errRFC8285OneByteHeaderIDRange, id)
          }
          if len(payload) > 16 {
            return fmt.Errorf("%w actual(%d)", errRFC8285OneByteHeaderSize, len(payload))
          }
        case extensionProfileTwoByte:
          if id < 1 || id > 255 {
            return fmt.Errorf("%w actual(%d)", errRFC8285TwoByteHeaderIDRange, id)
          }
          if len(payload) > 255 {
            return fmt.Errorf("%w actual(%d)", errRFC8285TwoByteHeaderSize, len(payload))
          }
        default:
          if id != 0 {
            return fmt.Errorf("%w actual(%d)", errRFC3550HeaderIDRange, id)
          }
        }

        // 如果扩展对应的id已存在,则更新;否则追加
        for i, extension := range h.Extensions {
          if extension.id == id {
            h.Extensions[i].payload = payload
            return nil
          }
        }
        h.Extensions = append(h.Extensions, Extension{id: id, payload: payload})
        return nil
      }

      // 如果这是添加的第一个扩展
      h.Extension = true

      // 根据第一个扩展来设置扩展profile
      switch len := len(payload); {
      case len <= 16:
        h.ExtensionProfile = extensionProfileOneByte
      case len > 16 && len < 256:
        h.ExtensionProfile = extensionProfileTwoByte
      }

      h.Extensions = append(h.Extensions, Extension{id: id, payload: payload})
      return nil
    }

对于Header还有一些其他方法:获取/删除/获取ids.

回到Packet,除了Header,还有Payload.

Packet的Marshal是将Marshalto封装了一下:

    func (p *Packet) MarshalTo(buf []byte) (n int, err error) {
      n, err = p.Header.MarshalTo(buf)
      if err != nil {
        return 0, err
      }

      if n+len(p.Payload) > len(buf) {
        return 0, io.ErrShortBuffer
      }

      m := copy(buf[n:], p.Payload)
      p.Raw = buf[:n+m]

      return n + m, nil
    }

序列化的同时,还将payload保存到Packet.Raw中.

    func (p *Packet) Unmarshal(rawPacket []byte) error {
      if err := p.Header.Unmarshal(rawPacket); err != nil {
        return err
      }

      p.Payload = rawPacket[p.PayloadOffset:]
      p.Raw = rawPacket
      return nil
    }

反序列化是先处理头,后处理payload.

总结一下: 打包器会将一段[]byte的payload打包成Packet,
目前唯一未分析到的扩展是paylaod切片的逻辑,这个存在子包中.
