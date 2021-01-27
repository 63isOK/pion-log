# pion/rtcp包

rtcp是rtp的姐妹协议,pion/rtcp实现了rfc3550和rfc5506.
rtcp采用的是out-of-band(oob,带外数据,和传输数据不是用的同一通道),
rtcp提供了一些rtp会话的统计信息和控制信息.

rtcp的主要作用是提供qos的反馈,
例如: 已传输字节/包数量/丢包数/延时/rtt延时等.
app可能会利用这些数据做控制服务参数,例如:限流/切换编码格式.

    /*
    Decoding RTCP packets:

      pkt, err := rtcp.Unmarshal(rtcpData)
      // ...

      switch p := pkt.(type) {
      case *rtcp.CompoundPacket:
        ...
      case *rtcp.PictureLossIndication:
        ...
      default:
        ...
      }

    Encoding RTCP packets:

      pkt := &rtcp.PictureLossIndication{
        SenderSSRC: senderSSRC,
        MediaSSRC: mediaSSRC
      }
      pliData, err := pkt.Marshal()
      // ...

    */

上面是一个rtcp包的序列化和反序列化的例子,后面统称rtcp的打包和解包过程.

rtcp包每个都很小,所以在传输时总是多个rtcp聚合到一起,然后传输.

## pion/rtcp支持的rtcp包类型

rtcp包的类型有很多,目前pion/rtcp实现并支持的rtcp类型在200-206之间

- 200 sr
- 201 rr
- 202 sdes
- 203 bye
- 204 app
- 205 rtpfb
- 206 psfb

其中rtpfb是传输相关的反馈,psfb是负载相关的反馈.

其中psfb还包含以下具体的消息类型:

- PLI,解码器会告知编码器,已经丢掉了数量不确定的视频编码数据
  - 此时发送者会重新发送一个关键帧
- SLI,解码器告知编码器,丢失了几个宏块
  - 此时发送者会重新发送一个关键帧
- FIR,同样是请求关键帧的消息
- REMB, 拥塞控制算法,接收端预估最大比特率

rtpfb还包含以下具体的消息类型:

- TLN, nack,负反馈,这个反馈是告知发送者丢了一些rtp包
- RRR, 快速同步请求,多用于mcu
- TCC, 也被称为twcc,发送端预估带宽

## rtcp.Header

rtcp包不管类型,都有一个共同的头,4字节

    type Header struct {
      Padding bool
      Count uint8
      Type PacketType
      Length uint16
    }

分别对应rtcp头中的几个信息,其中Count是5bit,随Type的不同而有不同的意思.

    func (h Header) Marshal() ([]byte, error) {
      /*
       *  0                   1                   2                   3
       *  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
       * +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       * |V=2|P|    RC   |   PT=SR=200   |             length            |
       * +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       */
      rawPacket := make([]byte, headerLength)

      rawPacket[0] |= rtpVersion << versionShift

      if h.Padding {
        rawPacket[0] |= 1 << paddingShift
      }

      if h.Count > 31 {
        return nil, errInvalidHeader
      }
      rawPacket[0] |= h.Count << countShift

      rawPacket[1] = uint8(h.Type)

      binary.BigEndian.PutUint16(rawPacket[2:], h.Length)

      return rawPacket, nil
    }

序列化里的内容比较简单.

    func (h *Header) Unmarshal(rawPacket []byte) error {
      if len(rawPacket) < headerLength {
        return errPacketTooShort
      }

      version := rawPacket[0] >> versionShift & versionMask
      if version != rtpVersion {
        return errBadVersion
      }

      h.Padding = (rawPacket[0] >> paddingShift & paddingMask) > 0
      h.Count = rawPacket[0] >> countShift & countMask

      h.Type = PacketType(rawPacket[1])

      h.Length = binary.BigEndian.Uint16(rawPacket[2:])

      return nil
    }

反序列化同样非常简单暴力.

## rtcp.Packet

rtcp包

    type Packet interface {
      DestinationSSRC() []uint32

      Marshal() ([]byte, error)
      Unmarshal(rawPacket []byte) error
    }

序列化和反序列化就是rtcp Packet对象和字节数组`[]byte`的转换.
DestinationSSRC方法返回rtcp包相关的ssrc.

    func Unmarshal(rawData []byte) ([]Packet, error) {
      var packets []Packet
      for len(rawData) != 0 {
        p, processed, err := unmarshal(rawData)
        if err != nil {
          return nil, err
        }

        packets = append(packets, p)
        rawData = rawData[processed:]
      }

      switch len(packets) {
      // Empty packet
      case 0:
        return nil, errInvalidHeader
      // Multiple Packets
      default:
        return packets, nil
      }
    }

反序列化,是通过unmarshal一个个将rtcp.Packet解出来的.

    func unmarshal(rawData []byte) (
      packet Packet, bytesprocessed int, err error) {

      var h Header

      // 将解前4个字节,这是rtcp的公共头
      err = h.Unmarshal(rawData)
      if err != nil {
        return nil, 0, err
      }

      bytesprocessed = int(h.Length+1) * 4
      if bytesprocessed > len(rawData) {
        return nil, 0, errPacketTooShort
      }
      inPacket := rawData[:bytesprocessed]

      // 拿到数据后,根据包类型构建Packet
      switch h.Type {
      case TypeSenderReport:
        packet = new(SenderReport)

      case TypeReceiverReport:
        packet = new(ReceiverReport)

      case TypeSourceDescription:
        packet = new(SourceDescription)

      case TypeGoodbye:
        packet = new(Goodbye)

      // 可以看到在rtpfb中,是通过Count来区分TLN/RRR/TCC
      case TypeTransportSpecificFeedback:
        switch h.Count {
        case FormatTLN:
          packet = new(TransportLayerNack)
        case FormatRRR:
          packet = new(RapidResynchronizationRequest)
        case FormatTCC:
          packet = new(TransportLayerCC)
        default:
          packet = new(RawPacket)
        }

      // 可以看到在psfb中,是通过Count来区分/PLI/SLI/REMB/FIR
      // REMB和TCC同属于拥塞控制算法,一个在负载反馈一个在传输反馈
      case TypePayloadSpecificFeedback:
        switch h.Count {
        case FormatPLI:
          packet = new(PictureLossIndication)
        case FormatSLI:
          packet = new(SliceLossIndication)
        case FormatREMB:
          packet = new(ReceiverEstimatedMaximumBitrate)
        case FormatFIR:
          packet = new(FullIntraRequest)
        default:
          packet = new(RawPacket)
        }

      default:
        // 最终还支持原始rtcp包
        packet = new(RawPacket)
      }

      // 这步是rtcp包数据进行反序列化
      err = packet.Unmarshal(inPacket)

      return packet, bytesprocessed, err
    }

在unmarsharl功能数中,每次处理一个rtcp包.

来看一下将多个rtcp Packet序列化到一个字符数组里:

    func Marshal(packets []Packet) ([]byte, error) {
      out := make([]byte, 0)
      for _, p := range packets {
        data, err := p.Marshal()
        if err != nil {
          return nil, err
        }
        out = append(out, data...)
      }
      return out, nil
    }

可以看到此处的序列化,直接使用rtcp.Packet的序列化.
回头看一下反序列化时,用字符数组来反序列化成Packet时,用的是一个完整的rtcp包数据,
所以此处在做序列化时,同样是用一个完整的rtcp包数据.

总结一下: pion/rtcp包第一个暴露的就是Packet包,和基于Packet的两个功能性函数:
将多个Packet序列化为字符数组;将字符数组反序列为多个Packet.

剩下的就是各个rtcp类型对Packet接口的实现.

## RawPacket

原始包,就是未解析的rtcp包.
这里的未解析是只未分析出rtcp包类型或具体的消息类型,头信息还是有的.

    type RawPacket []byte

    var _ Packet = (*RawPacket)(nil)

    func (r RawPacket) Marshal() ([]byte, error) {
      return r, nil
    }

    func (r *RawPacket) Unmarshal(b []byte) error {
      if len(b) < (headerLength) {
        return errPacketTooShort
      }
      *r = b

      var h Header
      return h.Unmarshal(b)
    }

    func (r RawPacket) Header() Header {
      var h Header
      if err := h.Unmarshal(r); err != nil {
        return Header{}
      }
      return h
    }

    func (r *RawPacket) DestinationSSRC() []uint32 {
      return []uint32{}
    }

对于原始rtcp,处理还是蛮简单的,

    func (r RawPacket) String() string {
      out := fmt.Sprintf("RawPacket: %v", ([]byte)(r))
      return out
    }

最后还添加了一个打印支持.

## SenderReport

先弄明白sr和rr的区别:

- sr/rr都是用于反馈接收质量的
- sr比rr多20个字节的数据,这20个字节包含了此参与者的信息
- 何时发sr,何时发rr
  - 如果上次发送report之后又发送了rtp数据,则发sr
  - 如果在一个report周期内,又发送了rtp数据,则发sr
  - 其他情况:在一个report周期内,没有发送rtp数据,则发rr
- rr是发给其他发送rtp数据的参与者:我收到了多少包,丢了多少,时间...
- sr是发给其他rtp参与者:我收到了多少,...,还包含我发送了多少,时间...

SenderReport的类型如下:

    type SenderReport struct {
      SSRC uint32
      NTPTime uint64
      RTPTime uint32
      PacketCount uint32
      OctetCount uint32
      Reports []ReceptionReport
      ProfileExtensions []byte
    }

对照rfc3550 6.4.1节的结构描述来看,依次是:

- 4字节的ssrc
- 8字节的ntp时间戳
- 4字节的rtp时间戳
- 4字节的发送rtp总包数
- 4字节的发送的payload总长度
- 多个报告块 report block
- profile-specific扩展

在头中,Count表示报告块的个数,PT是200.

    func (r SenderReport) Marshal() ([]byte, error) {

      rawPacket := make([]byte, r.len())
      packetBody := rawPacket[headerLength:]

      binary.BigEndian.PutUint32(packetBody[srSSRCOffset:], r.SSRC)
      binary.BigEndian.PutUint64(packetBody[srNTPOffset:], r.NTPTime)
      binary.BigEndian.PutUint32(packetBody[srRTPOffset:], r.RTPTime)
      binary.BigEndian.PutUint32(packetBody[srPacketCountOffset:], r.PacketCount)
      binary.BigEndian.PutUint32(packetBody[srOctetCountOffset:], r.OctetCount)

      // sr的整个头是24字节
      offset := srHeaderLength
      for _, rp := range r.Reports {
        data, err := rp.Marshal()
        if err != nil {
          return nil, err
        }
        copy(packetBody[offset:], data)

        // 每个报告块的长度都是24字节
        offset += receptionReportLength
      }

      // Count只有5bit,不能超过31个报告块
      if len(r.Reports) > countMax {
        return nil, errTooManyReports
      }

      copy(packetBody[offset:], r.ProfileExtensions)

      // 最后补上4字节的公共头
      hData, err := r.Header().Marshal()
      if err != nil {
        return nil, err
      }
      copy(rawPacket, hData)

      return rawPacket, nil
    }

序列化是将SenderReport的数据组成字符数组,相对简单.

    func (r *SenderReport) Unmarshal(rawPacket []byte) error {

      // 4字节的rtcp公共头 + 24字节的sr头
      if len(rawPacket) < (headerLength + srHeaderLength) {
        return errPacketTooShort
      }

      var h Header
      if err := h.Unmarshal(rawPacket); err != nil {
        return err
      }

      if h.Type != TypeSenderReport {
        return errWrongType
      }

      packetBody := rawPacket[headerLength:]

      r.SSRC = binary.BigEndian.Uint32(packetBody[srSSRCOffset:])
      r.NTPTime = binary.BigEndian.Uint64(packetBody[srNTPOffset:])
      r.RTPTime = binary.BigEndian.Uint32(packetBody[srRTPOffset:])
      r.PacketCount = binary.BigEndian.Uint32(packetBody[srPacketCountOffset:])
      r.OctetCount = binary.BigEndian.Uint32(packetBody[srOctetCountOffset:])

      offset := srReportOffset
      for i := 0; i < int(h.Count); i++ {
        rrEnd := offset + receptionReportLength
        if rrEnd > len(packetBody) {
          return errPacketTooShort
        }
        rrBody := packetBody[offset : offset+receptionReportLength]
        offset = rrEnd

        var rr ReceptionReport
        if err := rr.Unmarshal(rrBody); err != nil {
          return err
        }
        r.Reports = append(r.Reports, rr)
      }

      // 剩下的丢给profile 扩展
      if offset < len(packetBody) {
        r.ProfileExtensions = packetBody[offset:]
      }

      // 最后还做了一次report块的校验
      if uint8(len(r.Reports)) != h.Count {
        return errInvalidHeader
      }

      return nil
    }

和序列化一样,在反序列化中都没有对报告块做分析.

    func (r *SenderReport) DestinationSSRC() []uint32 {
      out := make([]uint32, len(r.Reports)+1)
      for i, v := range r.Reports {
        out[i] = v.SSRC
      }
      out[len(r.Reports)] = r.SSRC
      return out
    }

DestinationSSRC的目的是获取报告块中的ssrc.

    func (r SenderReport) String() string {
      out := fmt.Sprintf("SenderReport from %x\n", r.SSRC)
      out += fmt.Sprintf("\tNTPTime:\t%d\n", r.NTPTime)
      out += fmt.Sprintf("\tRTPTIme:\t%d\n", r.RTPTime)
      out += fmt.Sprintf("\tPacketCount:\t%d\n", r.PacketCount)
      out += fmt.Sprintf("\tOctetCount:\t%d\n", r.OctetCount)

      out += "\tSSRC    \tLost\tLastSequence\n"
      for _, i := range r.Reports {
        out += fmt.Sprintf("\t%x\t%d/%d\t%d\n",
          i.SSRC, i.FractionLost, i.TotalLost, i.LastSequenceNumber)
      }
      out += fmt.Sprintf("\tProfile Extension Data: %v\n", r.ProfileExtensions)
      return out
    }

打印也支持.
