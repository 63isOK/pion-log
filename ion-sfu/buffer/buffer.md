# Buffer

文件分析:
这个文件暴露的是Buffer类型,其中还包含不少其他类型:

- Stats
- pendingPackets/ExtPacket 
- Option

这些类型各有用处,有的仅仅作为Buffer内部使用,有的作为外部扩展,
有的作为方法参数,下面一一分析.

		type Buffer struct {
			sync.Mutex
			bucket     *Bucket // 桶,可装rtp包,维护丢包队列
			codecType  webrtc.RTPCodecType // 音频还是视频
			videoPool  *sync.Pool
			audioPool  *sync.Pool
			packetChan chan ExtPacket // 并发交互
			pPackets   []pendingPackets
			closeOnce  sync.Once
			mediaSSRC  uint32
			clockRate  uint32
			maxBitrate uint64
			lastReport int64
			twccExt    uint8
			audioExt   uint8
			bound      bool
			closed     atomicBool
			mime       string

			// supported feedbacks
			remb       bool
			nack       bool
			twcc       bool
			audioLevel bool

			minPacketProbe     int
			lastPacketRead     int
			maxTemporalLayer   int64
			bitrate            uint64
			bitrateHelper      uint64
			lastSRNTPTime      uint64
			lastSRRTPTime      uint32
			lastSRRecv         int64
			baseSN             uint16
			cycles             uint32
			lastRtcpPacketTime int64
			lastRtcpSrTime     int64
			lastTransit        uint32
			maxSeqNo           uint16

			stats Stats

			latestTimestamp     uint32
			latestTimestampTime int64

			// callbacks
			onClose      func()
			onAudioLevel func(level uint8)
			feedbackCB   func([]rtcp.Packet)
			feedbackTWCC func(sn uint16, timeNS int64, marker bool)
		}

这个结构体包含的字段非常多,具体提供什么功能还需要看提供的方法.
因为方法实在太多,需要的上下文也非常多,所以结合Factory一起分析.

		type Factory struct {
			sync.RWMutex
			videoPool   *sync.Pool
			audioPool   *sync.Pool
			rtpBuffers  map[uint32]*Buffer
			rtcpReaders map[uint32]*RTCPReader
		}

		func NewBufferFactory() *Factory {
			return &Factory{
				videoPool: &sync.Pool{
					New: func() interface{} {
						// Make a 2MB buffer for video
						return make([]byte, 2*1000*1000)
					},
				},
				audioPool: &sync.Pool{
					New: func() interface{} {
						// Make a max 25 packets buffer for audio
						return make([]byte, maxPktSize*25)
					},
				},
				rtpBuffers:  make(map[uint32]*Buffer),
				rtcpReaders: make(map[uint32]*RTCPReader),
			}
		}

Factory内部使用了Buffer和RTCPReader,是整个buffer包对外暴露的最重要的类型.
sync.Pool的使用是为了减少Go的gc,视频2M,音频25个包.

		func (f *Factory) GetOrNew(packetType packetio.BufferPacketType, ssrc uint32) io.ReadWriteCloser {
			f.Lock()
			defer f.Unlock()
			switch packetType {
			case packetio.RTCPBufferPacket:
				if reader, ok := f.rtcpReaders[ssrc]; ok {
					return reader
				}
				reader := NewRTCPReader(ssrc)
				f.rtcpReaders[ssrc] = reader
				reader.OnClose(func() {
					f.Lock()
					delete(f.rtcpReaders, ssrc)
					f.Unlock()
				})
				return reader
			case packetio.RTPBufferPacket:
				if reader, ok := f.rtpBuffers[ssrc]; ok {
					return reader
				}
				buffer := NewBuffer(ssrc, f.videoPool, f.audioPool)
				f.rtpBuffers[ssrc] = buffer
				buffer.OnClose(func() {
					f.Lock()
					delete(f.rtpBuffers, ssrc)
					f.Unlock()
				})
				return buffer
			}
			return nil
		}

先看这个是因为这个调用了Buffer的构造函数.
packetio包里定义了两种数据:rtcp和rtp.

GetOrNew方法,就是为了拿到当前数据对应的缓冲 io.ReadWriteCloser.
在GetOrNew中会通过数据类型和ssrc找到一个具体的读写对象.
同时指定了close回调.

		func (f *Factory) GetBufferPair(ssrc uint32) (*Buffer, *RTCPReader) {
			f.RLock()
			defer f.RUnlock()
			return f.rtpBuffers[ssrc], f.rtcpReaders[ssrc]
		}

		func (f *Factory) GetBuffer(ssrc uint32) *Buffer {
			f.RLock()
			defer f.RUnlock()
			return f.rtpBuffers[ssrc]
		}

		func (f *Factory) GetRTCPReader(ssrc uint32) *RTCPReader {
			f.RLock()
			defer f.RUnlock()
			return f.rtcpReaders[ssrc]
		}

Factory提供的其他方法就是获取读写对象,可以是同时获取rtcp/rtp的,也可以单独获取.

## 小结

rtp的读写对象Buffer还未分析,但rtcp读写对象已经分析了,
RTCPReader还有一个扩展,是丢给外部去扩展的:OnPacket,在Write时触发.
rtcp读写对象只有写操作,读操作被屏蔽了.

## Buffer

rtp的读写对象,实现了io.ReadWriteCloser接口.

		// NewBuffer constructs a new Buffer
		func NewBuffer(ssrc uint32, vp, ap *sync.Pool) *Buffer {
			b := &Buffer{
				mediaSSRC:  ssrc,
				videoPool:  vp,
				audioPool:  ap,
				packetChan: make(chan ExtPacket, 100),
			}
			return b
		}

构造时,指定了ssrc,也指定了读写缓冲.

通用Buffer也支持close回调:

		func (b *Buffer) Close() error {
			b.Lock()
			defer b.Unlock()

			b.closeOnce.Do(func() {

				// 设置关闭标识符
				b.closed.set(true)

				if b.bucket != nil && b.codecType == webrtc.RTPCodecTypeVideo {
					b.videoPool.Put(b.bucket.buf)
				}
				if b.bucket != nil && b.codecType == webrtc.RTPCodecTypeAudio {
					b.audioPool.Put(b.bucket.buf)
				}
				// 释放Factory中的map元素
				b.onClose()
				// 清理资源
				close(b.packetChan)
			})
			return nil
		}

		func (b *Buffer) OnClose(fn func()) {
			b.onClose = fn
		}

在Close调用时触发这个外部回调.从Factory的GetOrNew中可以看出,
不管是rtcp还是rtp,这个外部回调就是从Factory维护的map中移除指定ssrc对应的信息.

除了Close回调,还剩下3个回调:

		func (b *Buffer) OnAudioLevel(fn func(level uint8)) {
			b.onAudioLevel = fn
		}
		func (b *Buffer) OnFeedback(fn func(fb []rtcp.Packet)) {
			b.feedbackCB = fn
		}
		func (b *Buffer) OnTransportWideCC(fn func(sn uint16, timeNS int64, marker bool)) {
			b.feedbackTWCC = fn
		}

这3个回调函数的设置都在pion/ion-sfu/sfu包中,router.AddReceiver中指定的,
也正式在这儿通过ssrc来获取rtp/rtcp具体的读写对象.
同时RTCPReader的OnPacket回调也是在这里设置的.

		func (b *Buffer) Bind(params webrtc.RTPParameters, o Options) {
			b.Lock()
			defer b.Unlock()

			// 默认使用第一个编码设置
			codec := params.Codecs[0]
			b.clockRate = codec.ClockRate
			b.maxBitrate = o.MaxBitRate
			b.mime = strings.ToLower(codec.MimeType)

			// 确定是音视频后,构造了一个新的桶Bucket
			// 缓冲就是之前Buffer初始化的缓冲
			switch {
			case strings.HasPrefix(b.mime, "audio/"):
				b.codecType = webrtc.RTPCodecTypeAudio
				b.bucket = NewBucket(b.audioPool.Get().([]byte), false)
			case strings.HasPrefix(b.mime, "video/"):
				b.codecType = webrtc.RTPCodecTypeVideo
				b.bucket = NewBucket(b.videoPool.Get().([]byte), true)
			default:
				b.codecType = webrtc.RTPCodecType(0)
			}

			for _, ext := range params.HeaderExtensions {
				if ext.URI == sdp.TransportCCURI {
					b.twccExt = uint8(ext.ID)
					break
				}
			}

			if b.codecType == webrtc.RTPCodecTypeVideo {
				for _, fb := range codec.RTCPFeedback {
					switch fb.Type {
					case webrtc.TypeRTCPFBGoogREMB:
						log.Debugf("Setting feedback %s", webrtc.TypeRTCPFBGoogREMB)
						b.remb = true
					case webrtc.TypeRTCPFBTransportCC:
						log.Debugf("Setting feedback %s", webrtc.TypeRTCPFBTransportCC)
						b.twcc = true
					case webrtc.TypeRTCPFBNACK:
						log.Debugf("Setting feedback %s", webrtc.TypeRTCPFBNACK)
						b.nack = true
					}
				}
			} else if b.codecType == webrtc.RTPCodecTypeAudio {
				for _, h := range params.HeaderExtensions {
					if h.URI == sdp.AudioLevelURI {
						b.audioLevel = true
						b.audioExt = uint8(h.ID)
					}
				}
			}

			b.bucket.onLost = func(nacks []rtcp.NackPair, askKeyframe bool) {
				pkts := []rtcp.Packet{&rtcp.TransportLayerNack{
					MediaSSRC: b.mediaSSRC,
					Nacks:     nacks,
				}}

				if askKeyframe {
					pkts = append(pkts, &rtcp.PictureLossIndication{
						MediaSSRC: b.mediaSSRC,
					})
				}

				b.feedbackCB(pkts)
			}

			for _, pp := range b.pPackets {
				b.calc(pp.packet, pp.arrivalTime)
			}
			b.pPackets = nil
			b.bound = true

			log.Debugf("NewBuffer BufferOptions=%v", o)
		}

Bind方法是在构造之后,第一个需要调用的方法,里面做了不少初始化,
具体的分析见注释.

2021/02/05 分析暂停,里面扯的层数太深了,需要停一下.
