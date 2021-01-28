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

## ReceptionReport

报告块,这个是用于告诉推流者,本端收流的质量信息.

这个报告是基于ssrc的.

    type ReceptionReport struct {
      SSRC uint32
      FractionLost uint8
      TotalLost uint32
      LastSequenceNumber uint32
      Jitter uint32
      LastSenderReport uint32
      Delay uint32
    }

按rfc3550 6.4.1说明,这个报告块的长度是24字节:

- SSRC 4字节,指明是针对哪个源的接收报告
- FractionLost, 1字节,从上次发送sr/rr包到现在,rtp丢包率,小数表示
- TotalLost, 3字节,rtp包总的丢包数量
- LastSequenceNumber, 4字节,低16位是接收的最大rtp序号,高16位存rtp序号重置次数
- Jitter, 4字节,rtp包到达间隔时间的一个方差估计,也称抖动
- LastSenderPeport, 4字节,从源收到的最新sr包中的ntp时间戳中的32位,如果没收到sr,则为0
- Delay, 4字节,单位1/2的16次方秒,是从源收到sr包到发送此包的时间,如果源没有发sr,则为0

这个报告块包含了很多信息,具体如何使用,就看上层业务如何调度,我们先看报告块的方法:

    func (r ReceptionReport) Marshal() ([]byte, error) {
      rawPacket := make([]byte, receptionReportLength)

      binary.BigEndian.PutUint32(rawPacket, r.SSRC)

      rawPacket[fractionLostOffset] = r.FractionLost

      if r.TotalLost >= (1 << 25) {
        return nil, errInvalidTotalLost
      }

      // 高字节保存在低地址,大端模式
      tlBytes := rawPacket[totalLostOffset:]
      tlBytes[0] = byte(r.TotalLost >> 16)
      tlBytes[1] = byte(r.TotalLost >> 8)
      tlBytes[2] = byte(r.TotalLost)

      binary.BigEndian.PutUint32(rawPacket[lastSeqOffset:], r.LastSequenceNumber)
      binary.BigEndian.PutUint32(rawPacket[jitterOffset:], r.Jitter)
      binary.BigEndian.PutUint32(rawPacket[lastSROffset:], r.LastSenderReport)
      binary.BigEndian.PutUint32(rawPacket[delayOffset:], r.Delay)

      return rawPacket, nil
    }

    func (r *ReceptionReport) Unmarshal(rawPacket []byte) error {
      if len(rawPacket) < receptionReportLength {
        return errPacketTooShort
      }

      r.SSRC = binary.BigEndian.Uint32(rawPacket)
      r.FractionLost = rawPacket[fractionLostOffset]

      tlBytes := rawPacket[totalLostOffset:]
      r.TotalLost = uint32(tlBytes[2]) | uint32(tlBytes[1])<<8 | uint32(tlBytes[0])<<16

      r.LastSequenceNumber = binary.BigEndian.Uint32(rawPacket[lastSeqOffset:])
      r.Jitter = binary.BigEndian.Uint32(rawPacket[jitterOffset:])
      r.LastSenderReport = binary.BigEndian.Uint32(rawPacket[lastSROffset:])
      r.Delay = binary.BigEndian.Uint32(rawPacket[delayOffset:])

      return nil
    }

因为有rfc标准,所以报告块的序列化和反序列化都很简单,难的是如何在应用层去使用这些信息.

## ReceiverReport

作为流的接收者,发送给发流者的反馈信息.
rr作为sr的一个简写部分,大部分数据和结构都是类似的.

作为开源作者,从来不会在两个相同的地方使用同一个招式,而是各种秀.

因为sr和rr的部分代码逻辑类似,下面只挑一些不同的来说.

在序列化时,考虑到了最后的扩展有可能不满4字节的情况:

    for (len(pe) & 0x3) != 0 {
      pe = append(pe, 0)
    }

在反序列化时倒没考虑填充的问题,因为反序列化时无法考虑这种情况.

## SourceDescription

sdes类型的rtcp包,源描述包.

下面是rtcp包组合中的几条约束:

- 只要带宽允许,sr/rr应该经常发,每个发送周期,都必须报告报告包
- 每个组合包,都应该包含sdes包,更具体一点,是应该包含sdes包中的cname
  - 新接收者可以通过cname来识别ssrc,并进行流同步
- rtcp组合包的长度是受限于mtu的,需要注意组合包数量

sdes类型的rtcp包除了公共头,剩下的就是一个个chunk块,
chunk块里包含ssrc/csrc信息和具体的sdes信息,所以也称为3层结构.
公共头里的Count就指明了chunk块的数量.

    /*
     *         0                   1                   2                   3
     *         0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
     *        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     * header |V=2|P|    SC   |  PT=SDES=202  |             length            |
     *        +=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+
     * chunk  |                          SSRC/CSRC_1                          |
     *   1    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     *        |                           SDES items                          |
     *        |                              ...                              |
     *        +=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+
     * chunk  |                          SSRC/CSRC_2                          |
     *   2    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     *        |                           SDES items                          |
     *        |                              ...                              |
     *        +=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+
     */

ssrc/csrc每个都占4个字节,下面来说下sdes items:

sdes items描述的条目有很多:

- cname 规范名字
- Nmae 用户名
- Email 邮件
- Phone 电话
- Location 地址
- Tool app或工具名
- Note 提示
- Private 隐私信息

她们都有一个共同的开头:

    /*
     *   0                   1                   2                   3
     *   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
     *  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     *  |    CNAME=1    |     length    | user and domain name        ...
     *  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     */

再看看处理过程:

    type SourceDescription struct {
      Chunks []SourceDescriptionChunk
    }

SourceDescription实现了Packet接口,在序列化和反序列化时,
针对chunk块,使用的是SourceDescriptionChunk.

    type SourceDescriptionChunk struct {
      Source uint32
      Items  []SourceDescriptionItem
    }

在SourceDescriptionChunk的序列化和反序列化中,使用到了SourceDescriptionItem:

    type SourceDescriptionItem struct {
      Type SDESType
      Text string
    }

在序列化时,chunk块设置长度时有特殊处理,这是rfc上规定的:

    func (s SourceDescriptionChunk) len() int {
      len := sdesSourceLen
      for _, it := range s.Items {
        len += it.len()
      }

      // 这步是让每个chunk块以0x00结尾
      len += sdesTypeLen

      // 下面这个是填充,以和4字节对齐
      len += getPadding(len)

      return len
    }

下面从头到位分析以下序列化的流程:

    func (s SourceDescription) Marshal() ([]byte, error) {

      // 计算rtcp包的总长度
      rawPacket := make([]byte, s.len())
      packetBody := rawPacket[headerLength:]

      chunkOffset := 0
      for _, c := range s.Chunks {
        data, err := c.Marshal()
        if err != nil {
          return nil, err
        }
        copy(packetBody[chunkOffset:], data)
        chunkOffset += len(data)
      }

      if len(s.Chunks) > countMax {
        return nil, errTooManyChunks
      }

      hData, err := s.Header().Marshal()
      if err != nil {
        return nil, err
      }
      copy(rawPacket, hData)

      return rawPacket, nil
    }

接下来看每个chunk块的序列化:

    func (s SourceDescriptionChunk) Marshal() ([]byte, error) {

      rawPacket := make([]byte, sdesSourceLen)
      binary.BigEndian.PutUint32(rawPacket, s.Source)

      for _, it := range s.Items {
        data, err := it.Marshal()
        if err != nil {
          return nil, err
        }
        rawPacket = append(rawPacket, data...)
      }

      // 这儿就是具体在chunk后添加空字节0x00的逻辑
      rawPacket = append(rawPacket, uint8(SDESEnd))
      rawPacket = append(rawPacket, make([]byte, getPadding(len(rawPacket)))...)

      return rawPacket, nil
    }

chunk里分ssrc/csrc和item,item的序列化如下:

    func (s SourceDescriptionItem) Marshal() ([]byte, error) {
      if s.Type == SDESEnd {
        return nil, errSDESMissingType
      }

      rawPacket := make([]byte, sdesTypeLen+sdesOctetCountLen)

      // item设置type
      rawPacket[sdesTypeOffset] = uint8(s.Type)

      txtBytes := []byte(s.Text)
      octetCount := len(txtBytes)
      if octetCount > sdesMaxOctetCount {
        return nil, errSDESTextTooLong
      }

      // item设置length
      rawPacket[sdesOctetCountOffset] = uint8(octetCount)

      // item设置内容
      rawPacket = append(rawPacket, txtBytes...)

      return rawPacket, nil
    }

sdes类型的rtcp的反序列化也是类似的.

    func (s *SourceDescription) DestinationSSRC() []uint32 {
      out := make([]uint32, len(s.Chunks))
      for i, v := range s.Chunks {
        out[i] = v.Source
      }
      return out
    }

sdes的DestinationSSRC是获取chunk的数量.

## Goodbye

bye类型的rtcp包,用于表明某些源不再活跃.

    /*
     *        0                   1                   2                   3
     *        0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
     *       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     *       |V=2|P|    SC   |   PT=BYE=203  |             length            |
     *       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     *       |                           SSRC/CSRC                           |
     *       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     *       :                              ...                              :
     *       +=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+
     * (opt) |     length    |               reason for leaving            ...
     *       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
     */

不再活跃的源可以是多个ssrc或csrc,bye包中还可以包含可选的原因.
最后离开的原因的处理和sdes中的chunk填充处理是一致的.

    type Goodbye struct {
      Sources []uint32
      Reason string
    }

    func (g Goodbye) Marshal() ([]byte, error) {

      // 计算整个bye包的长度
      rawPacket := make([]byte, g.len())
      packetBody := rawPacket[headerLength:]

      if len(g.Sources) > countMax {
        return nil, errTooManySources
      }

      // 拷贝ssrc
      for i, s := range g.Sources {
        binary.BigEndian.PutUint32(packetBody[i*ssrcLength:], s)
      }

      // 复制原因
      if g.Reason != "" {
        reason := []byte(g.Reason)

        if len(reason) > sdesMaxOctetCount {
          return nil, errReasonTooLong
        }

        reasonOffset := len(g.Sources) * ssrcLength
        packetBody[reasonOffset] = uint8(len(reason))
        copy(packetBody[reasonOffset+1:], reason)
      }

      // 设置公共头
      hData, err := g.Header().Marshal()
      if err != nil {
        return nil, err
      }
      copy(rawPacket, hData)

      return rawPacket, nil
    }

反序列化也是类似.

## TransportLayerNack

rtpfb中的tln,传输丢包.

现在rtp传输层的nack反馈只有一种通用的nack.
她的作用就是通知丢了一个或多个rtp包.

一旦底层的传输协议提供了类似的"向发送端反馈信息"的机制,
则不应该使用通用nack.

rtcp中的反馈包包含3个层级的:

- 传输层反馈
- 负载层反馈
- app层反馈

反馈包的统一格式如下:

    // 0                   1                   2                   3
    // 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |V=2|P|  FMT    |    PT         |           length              |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                     SSRC of packet sender                     |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                      SSRC of media source                     |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |              feedback control information(FCI)                |

和通用的rtcp头相比,通用头的Count用于表示一些ssrc或chunk或报告包的数量,
在反馈包中,FMT用于表示PT下的细类.
对于tln,PT=205,FMT=15.

ssrc of packet sender:发送此包的原始ssrc.
ssrc of media source:这个nack包所关联的哪些ssrc,就是这些ssrc的rtp包丢了.
FCI,4字节,决定了哪些信息.

    // 0                   1                   2                   3
    // 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |        PID                  |       BLP                       |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

上面就是通用nack的fci.

PID,2字节,是丢失的一个rtp包的序号.
BLP,是后续丢的数据包的掩码位,是基于PID来计算的.

可以看出,每次反馈某个rtp包及后面16个包的情况,如果之后第二个包丢失,就将第二位设置为1.
注意:设置为0并不代表对应的rtp已经收到了,只表明在本次反馈中,没有将第x位标记为丢失.

    type PacketBitmap uint16

    type NackPair struct {
      PacketID uint16
      LostPackets PacketBitmap
    }

    type TransportLayerNack struct {
      SenderSSRC uint32
      MediaSSRC uint32
      Nacks []NackPair
    }

对应tln的类型,一个tln是可以带多个fci的.
rfc还规定了反馈消息的长度是n+2,n为nack数量(一个nack就是一个fci),
在代码中的体现是n+2不能超过255,具体的依据还没找到,估计在rfc的哪个角落.

    func (p TransportLayerNack) Marshal() ([]byte, error) {
      if len(p.Nacks)+tlnLength > math.MaxUint8 {
        return nil, errTooManyReports
      }

      rawPacket := make([]byte, nackOffset+(len(p.Nacks)*4))
      binary.BigEndian.PutUint32(rawPacket, p.SenderSSRC)
      binary.BigEndian.PutUint32(rawPacket[4:], p.MediaSSRC)
      for i := 0; i < len(p.Nacks); i++ {
        binary.BigEndian.PutUint16(rawPacket[nackOffset+(4*i):], p.Nacks[i].PacketID)
        binary.BigEndian.PutUint16(rawPacket[nackOffset+(4*i)+2:], uint16(p.Nacks[i].LostPackets))
      }
      h := p.Header()
      hData, err := h.Marshal()
      if err != nil {
        return nil, err
      }

      return append(hData, rawPacket...), nil
    }

tln的结构简单,所以序列化也简单.

这里单独对NackPair提供了几个方法:

    func (n *NackPair) Range(f func(seqno uint16) bool) {
      more := f(n.PacketID)
      if !more {
        return
      }

      b := n.LostPackets
      for i := uint16(0); b != 0; i++ {
        if (b & (1 << i)) != 0 {
          b &^= (1 << i)
          more = f(n.PacketID + i + 1)
          if !more {
            return
          }
        }
      }
    }

单独看这个方法,没什么头绪,要结合下面的方法一起看:

    func (n *NackPair) PacketList() []uint16 {
      out := make([]uint16, 0, 17)
      n.Range(func(seqno uint16) bool {
        out = append(out, seqno)
        return true
      })
      return out
    }

用闭包来获取一个`[]uint16`,猜测是获取rtp序号.
结合Range来看,是获取丢包序号,最长不超过17个.

    func NackPairsFromSequenceNumbers(
      sequenceNumbers []uint16) (pairs []NackPair) {

      if len(sequenceNumbers) == 0 {
        return []NackPair{}
      }

      // 第一个nack数据
      nackPair := &NackPair{PacketID: sequenceNumbers[0]}
      for i := 1; i < len(sequenceNumbers); i++ {
        m := sequenceNumbers[i]

        // 如果pid超过了当前nack的pid+16, 则新建一个nack包
        if m-nackPair.PacketID > 16 {
          pairs = append(pairs, *nackPair)
          nackPair = &NackPair{PacketID: m}
          continue
        }

        // 当前迭代的rtp序号可添加到nack中
        nackPair.LostPackets |= 1 << (m - nackPair.PacketID - 1)
      }

      // 处理最后一个nack,添加到nack队列
      pairs = append(pairs, *nackPair)
      return
    }

看明白后,这个生成nack队列的功能函数非常精巧.简单就是美.

这里提供的都是一些nack底层的操作,上层会依据这些信息和操作来组合更加复杂的逻辑.

### RapidResynchronizationRequest

快速同步请求反馈,也是rtp传输层的包.接收者会通知编码器:有一个或多个图片的数据丢失了.

rfc上说到:媒体接收者无法同步某些媒体流时,发送一个rrr给媒体发送者,
希望媒体发送者尽快发送一个sr包来.

    type RapidResynchronizationRequest struct {
      SenderSSRC uint32
      MediaSSRC uint32
    }

rrr没有fci.

    func (p RapidResynchronizationRequest) Marshal() ([]byte, error) {
      rawPacket := make([]byte, p.len())
      packetBody := rawPacket[headerLength:]

      binary.BigEndian.PutUint32(packetBody, p.SenderSSRC)
      binary.BigEndian.PutUint32(packetBody[rrrMediaOffset:], p.MediaSSRC)

      hData, err := p.Header().Marshal()
      if err != nil {
        return nil, err
      }
      copy(rawPacket, hData)

      return rawPacket, nil
    }

rrr的长度是4字节的公共头,8字节的反馈头.

其他部分和其他类型rtcp的类似,就不赘述了.

## TransportLayerCC

tcc,也被称为twcc,和remb称为带宽自适应的两大算法.

twcc的两大优势:

- 基于rtp包,而不是媒体流,更加适合拥塞控制
- 可以进行更早的丢包检测和恢复

如果要使用twcc,第一需要扩展rtp头,第二需要在sdp中告知"启用了twcc",
第三就是rtcp的支持.

因为pion/rtp支持了tcc,但在pion的其他项目中没有使用到,所以暂不分析rtcp的tcc.

## PictureLossIndication

pli,负载层的反馈.

    type PictureLossIndication struct {
      SenderSSRC uint32
      MediaSSRC uint32
    }

    func (p PictureLossIndication) Marshal() ([]byte, error) {
      rawPacket := make([]byte, p.len())
      packetBody := rawPacket[headerLength:]

      binary.BigEndian.PutUint32(packetBody, p.SenderSSRC)
      binary.BigEndian.PutUint32(packetBody[4:], p.MediaSSRC)

      h := Header{
        Count:  FormatPLI,
        Type:   TypePayloadSpecificFeedback,
        Length: pliLength,
      }
      hData, err := h.Marshal()
      if err != nil {
        return nil, err
      }
      copy(rawPacket, hData)

      return rawPacket, nil
    }

这种通知型的反馈,是不需要带FCI的,就如RRR一样.
pli,12字节,绝大部分逻辑都和rrr类似.

## SliceLossIndication

如果将一个图片分层多个小块,从左到右,从上到下,依次编号1-N,
sli就是反馈丢了哪些块,pli比较暴力,直接是整个丢了.

sli的fci如下:

    // 0                   1                   2                   3
    // 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |        First          |       Number            |  PictureID  |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

说明:

- First, 13位,第一个丢失的块
- Number, 13位,总共丢了多少块
- PictureID,图片的低6位id,和编码格式相关

对应的类型如下:

    type SLIEntry struct {
      First uint16
      Number uint16
      Picture uint8
    }

    type SliceLossIndication struct {
      SenderSSRC uint32
      MediaSSRC uint32
      SLI []SLIEntry
    }

在序列化和反序列化中,和其他类型的rtcp包类似,只是将常用的copy改为了append,
小改动.

## FullIntraRequest

fir,也是请求关键帧的一种请求,和pli类似,但pli用于从错误中恢复,
而fir的应用场景是新参与者进入,会发送fir,合流,也会用到fir,
如果是从错误中恢复,不会使用fir,而是使用pli.

    // 0                   1                   2                   3
    // 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                     SSRC                                      |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |  seq nr.     |               reserved                         |

seq nr.是命令序号,1字节,可有多个fci.

    type FIREntry struct {
      SSRC           uint32
      SequenceNumber uint8
    }

    type FullIntraRequest struct {
      SenderSSRC uint32
      MediaSSRC  uint32
      FIR []FIREntry
    }

序列化和反序列化就不贴了,逻辑和其他包类似.

## ReceiverEstimatedMaximumBitrate

拥塞控制算法.

remb,和twcc一个是发送端的算法,一个是接收端的算法,两者的效果都是类似的.

remb就是估计一个会话的总可用带宽.

remb包,是向多个媒体发送方通知:我的总估计可用带宽.
发送方发送的带宽不能超过估计的总带宽,而且需要对改变发送带宽有快速的响应.

除了rtcp包,还需要在sdp中告知:启用了remb.

    /*
        0                   1                   2                   3
        0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |V=2|P| FMT=15  |   PT=206      |             length            |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                  SSRC of packet sender                        |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |                  SSRC of media source                         |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |  Unique identifier 'R' 'E' 'M' 'B'                            |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |  Num SSRC     | BR Exp    |  BR Mantissa                      |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |   SSRC feedback                                               |
       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
       |  ...                                                          |
    */

下面是对应的类型:

    type ReceiverEstimatedMaximumBitrate struct {
      SenderSSRC uint32
      Bitrate uint64
      SSRCs []uint32
    }

    func (p ReceiverEstimatedMaximumBitrate) Marshal() (buf []byte, err error) {
      // rebm的长度是20字节+4*ssrc数
      buf = make([]byte, p.MarshalSize())

      n, err := p.MarshalTo(buf)
      if err != nil {
        return nil, err
      }

      if n != len(buf) {
        return nil, errWrongMarshalSize
      }

      return buf, nil
    }

具体的序列化放在MarshalTo上面:

    func (p ReceiverEstimatedMaximumBitrate) MarshalTo(
      buf []byte) (n int, err error) {

      size := p.MarshalSize()
      if len(buf) < size {
        return 0, errPacketTooShort
      }

      buf[0] = 143 // v=2, p=0, fmt=15
      buf[1] = 206

      length := uint16((p.MarshalSize() / 4) - 1)
      binary.BigEndian.PutUint16(buf[2:4], length)

      binary.BigEndian.PutUint32(buf[4:8], p.SenderSSRC)
      binary.BigEndian.PutUint32(buf[8:12], 0) // always zero

      buf[12] = 'R'
      buf[13] = 'E'
      buf[14] = 'M'
      buf[15] = 'B'

      buf[16] = byte(len(p.SSRCs))

      // math/bits.LeadingZeros64是获取前面为0的个数
      // shift最终是比特率的位数
      shift := uint(64 - bits.LeadingZeros64(p.Bitrate))

      // 此处用到了指数和尾数的概念
      // 103020 = 1.0302 * 10的5次方
      // 那么1.0302就是尾数,5就是指数
      var mantissa uint
      var exp uint

      // 以2为底,用24位来存储比特率
      if shift <= 18 {
        mantissa = uint(p.Bitrate)
        exp = 0
      } else {
        mantissa = uint(p.Bitrate >> (shift - 18))
        exp = shift - 18
      }

      buf[17] = byte((exp << 2) | (mantissa >> 16))
      buf[18] = byte(mantissa >> 8)
      buf[19] = byte(mantissa)

      n = 20
      for _, ssrc := range p.SSRCs {
        binary.BigEndian.PutUint32(buf[n:n+4], ssrc)
        n += 4
      }

      return n, nil
    }

整个序列化里还是用到了不少新东西的.

最后在打印中,体现了不少好玩的单位.

## 组合包 CompoundPacket

rtcp包都非常小,所以很多都是聚合在一起发送,发送也有一些规则:

- 组合包的第一个包一定要是报告包sr或rr
  - 即使没有数据,也要发送一个空的rr包
  - 即使只有一个bye包要组合,也要添加一个空的rr包
- 每个组合包都应该包含一个含有cname条目的sdes包

类型就是`[]Packet`

    type CompoundPacket []Packet
    var _ Packet = (*CompoundPacket)(nil) // assert is a Packet

    func (c CompoundPacket) Marshal() ([]byte, error) {
      if err := c.Validate(); err != nil {
        return nil, err
      }

      p := []Packet(c)
      return Marshal(p)
    }

组合包的检查我们最后再看,我们分析rtcp时,
第一分析的对象是Packet和基于Packet数组的序列化和反序列化,正好在这里用上了.

    func (c *CompoundPacket) Unmarshal(rawData []byte) error {
      out := make(CompoundPacket, 0)
      for len(rawData) != 0 {
        p, processed, err := unmarshal(rawData)
        if err != nil {
          return err
        }

        out = append(out, p)
        rawData = rawData[processed:]
      }
      *c = out

      if err := c.Validate(); err != nil {
        return err
      }

      return nil
    }

现在分析最后一个,rfc规定的组合包校验流程:

    func (c CompoundPacket) Validate() error {
      if len(c) == 0 {
        return errEmptyCompound
      }

      // 组合包第一个包必须是报告包(sr/rr)
      switch c[0].(type) {
      case *SenderReport, *ReceiverReport:
        // ok
      default:
        return errBadFirstPacket
      }

      // 必须包含一个sdes.cname包
      // 而且sdes.cname前面只能有rr包(如果第一个是sr包的情况除外).
      for _, pkt := range c[1:] {
        switch p := pkt.(type) {
        case *ReceiverReport:
          continue

        case *SourceDescription:
          var hasCNAME bool
          for _, c := range p.Chunks {
            for _, it := range c.Items {
              if it.Type == SDESCNAME {
                hasCNAME = true
              }
            }
          }

          if !hasCNAME {
            return errMissingCNAME
          }

          return nil

        default:
          return errPacketBeforeCNAME
        }
      }

      return errMissingCNAME
    }

到此,pion/rtcp包分析完了,除了tcc没详细去分析,其他包都已经过了一遍.
