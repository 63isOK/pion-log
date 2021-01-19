# sfu包的分析

这是一个配置结构,用于加载配置文件config.toml.
还有一些字段对应的结构体,后面遇到再细说.

    type Config struct {
      SFU struct {
        Ballast   int64 `mapstructure:"ballast"`
        WithStats bool  `mapstructure:"withstats"`
      } `mapstructure:"sfu"`
      WebRTC WebRTCConfig `mapstructure:"webrtc"`
      Log    log.Config   `mapstructure:"log"`
      Router RouterConfig `mapstructure:"router"`
      Turn   TurnConfig   `mapstructure:"turn"`
    }

在sfu的入口处有这么几行,这就是加载配置:

    var conf = sfu.Config{}
    err = viper.GetViper().Unmarshal(&conf)
    s := sfu.NewSFU(conf)

整个配置Config最后是用来初始化sfu实例.

下面我们按照源文件顺序来分析一下

## sfu.go

对外暴露的第一个类型,传输配置,创建PeerConection时需要用到这个配置.

    type WebRTCTransportConfig struct {
      configuration webrtc.Configuration
      setting       webrtc.SettingEngine
      router        RouterConfig
    }

    // 构造传输配置
    func NewWebRTCTransportConfig(c Config) WebRTCTransportConfig {
      se := webrtc.SettingEngine{}

      var icePortStart, icePortEnd uint16

      // 如果开启了turn中继,端口范围是46884-60999
      // 如果没开启,优先使用配置文件config.toml中指定的范围
      if c.Turn.Enabled {
        icePortStart = sfuMinPort
        icePortEnd = sfuMaxPort
      } else if len(c.WebRTC.ICEPortRange) == 2 {
        icePortStart = c.WebRTC.ICEPortRange[0]
        icePortEnd = c.WebRTC.ICEPortRange[1]
      }

      if icePortStart != 0 || icePortEnd != 0 {
        if err := se.SetEphemeralUDPPortRange(
            icePortStart, icePortEnd); err != nil {
          panic(err)
        }
      }

      var iceServers []webrtc.ICEServer
      if c.WebRTC.Candidates.IceLite {
        se.SetLite(c.WebRTC.Candidates.IceLite)
      } else {
        for _, iceServer := range c.WebRTC.ICEServers {
          s := webrtc.ICEServer{
            URLs:       iceServer.URLs,
            Username:   iceServer.Username,
            Credential: iceServer.Credential,
          }
          iceServers = append(iceServers, s)
        }
      }

      se.BufferFactory = bufferFactory.GetOrNew

      sdpSemantics := webrtc.SDPSemanticsUnifiedPlan
      switch c.WebRTC.SDPSemantics {
      case "unified-plan-with-fallback":
        sdpSemantics = webrtc.SDPSemanticsUnifiedPlanWithFallback
      case "plan-b":
        sdpSemantics = webrtc.SDPSemanticsPlanB
      }

      w := WebRTCTransportConfig{
        configuration: webrtc.Configuration{
          ICEServers:   iceServers,
          SDPSemantics: sdpSemantics,
        },
        setting: se,
        router:  c.Router,
      }

      if len(c.WebRTC.Candidates.NAT1To1IPs) > 0 {
        w.setting.SetNAT1To1IPs(c.WebRTC.Candidates.NAT1To1IPs, webrtc.ICECandidateTypeHost)
      }

      if c.SFU.WithStats {
        w.router.WithStats = true
        stats.InitStats()
      }

      return w
    }

这里的传输对象构造,是基于配置来的,会应用于所有会话,整个过程中是不会变更的.
sdp的两种组织方式 plan b和unified plan,
首先出现的是plan a,一个peerconnection对应一个流;
之后被plan b取代,plan b是sdp中的一个媒体级(m=)包含多个流,流和流之间用msid区分;
现在plan b逐渐被jsep规定的unified plan取代,
unified plan是sdp中的一个媒体级(m=)表示一个流,sdp可以包含多个媒体级,
现在主流浏览器都慢慢切到jsep规定的标准上了.

对外暴露的第二个类型是SFU,SFU表示一个sfu实例.

    type SFU struct {
      sync.RWMutex
      webrtc    WebRTCTransportConfig
      router    RouterConfig
      turn      *turn.Server
      sessions  map[string]*Session
      withStats bool
    }

SFU包含了传输配置WebRTCTransportConfig,也包含了一个turn服务,
同时还维护了一个会话列表,会话是webrtc流转发的边界.

    func NewSFU(c Config) *SFU {
      // Init random seed
      rand.Seed(time.Now().UnixNano())
      // Init ballast
      ballast := make([]byte, c.SFU.Ballast*1024*1024)
      // Init buffer factory
      bufferFactory = buffer.NewBufferFactory()
      // Init packet factory
      packetFactory = &sync.Pool{
        New: func() interface{} {
          return make([]byte, 1460)
        },
      }

      w := NewWebRTCTransportConfig(c)

      s := &SFU{
        webrtc:    w,
        sessions:  make(map[string]*Session),
        withStats: c.Router.WithStats,
      }

      if c.Turn.Enabled {
        ts, err := initTurnServer(c.Turn, nil)
        if err != nil {
          log.Panicf("Could not init turn server err: %v", err)
        }
        s.turn = ts
      }

      runtime.KeepAlive(ballast)
      return s
    }

这个sfu实例构造有些好玩的东西:

- sync.Pool 临时对象单独的存放和检索,目的是减少gc压力
- runtime.KeepAlive 保活

ballast申请指定大小的内存,用意是减少触发gc的次数.

先不看具体的标准库,来看看sfu实例的构造还做了什么事:
initTurnServer,因为pion实现了自己的turn服务,也集成到ion项目中了,
此处是直接启动turn服务.

对于SFU,还有几个方法:

    // 这里是构建了一个新的Session,下一步就分析这个
    func (s *SFU) newSession(id string) *Session {
      session := NewSession(id)

      session.OnClose(func() {
        s.Lock()
        delete(s.sessions, id)
        s.Unlock()

        if s.withStats {
          stats.Sessions.Dec()
        }
      })

      s.Lock()
      s.sessions[id] = session
      s.Unlock()

      if s.withStats {
        stats.Sessions.Inc()
      }

      return session
    }

    func (s *SFU) getSession(id string) *Session {
      s.RLock()
      defer s.RUnlock()
      return s.sessions[id]
    }

    func (s *SFU) GetSession(sid string) (*Session, WebRTCTransportConfig) {
      session := s.getSession(sid)
      if session == nil {
        session = s.newSession(sid)
      }
      return session, s.webrtc
    }

SFU内嵌了sync.RWMutex读写锁.
SFU.GetSession()总会返回一个会话和传输配置,
传输配置是固定的,如果会话id不存在,就新建一个会话.

## session.go

对外暴露的是Session类型:

    type Session struct {
      id             string
      mu             sync.RWMutex
      peers          map[string]*Peer
      onCloseHandler func()
      closed         bool
    }

Session.peers维护了当前会话中的所有参与者.
一个会话中的参与者会自动订阅其他参与者的流.

构造非常简单,只需要提供会话id.

    func NewSession(id string) *Session {
      return &Session{
        id:     id,
        peers:  make(map[string]*Peer),
        closed: false,
      }
    }

sfu.Peer是代表PeerConnection的对象,是下一步分析的类型.
sfu.Session中peers是非暴露的,所以会有方法来对参与者做维护:

    func (s *Session) AddPeer(peer *Peer) {
      s.mu.Lock()
      s.peers[peer.id] = peer
      s.mu.Unlock()
    }

    func (s *Session) RemovePeer(pid string) {
      s.mu.Lock()
      log.Infof("RemovePeer %s from session %s", pid, s.id)
      delete(s.peers, pid)
      s.mu.Unlock()

      if len(s.peers) == 0 && s.onCloseHandler != nil && !s.closed {
        s.onCloseHandler()
        s.closed = true
      }
    }

参与者离开会话,当会话的参与者数量为0时,会触发一次sfu.Session.onCloseHandler(),
这个是在会话关闭时调用的.

每个参与者都有一个区分的标识符,下面是通过标识符查参与者/设置会话关闭处理:

    func (s *Session) Peers() map[string]*Peer {
      s.mu.RLock()
      defer s.mu.RUnlock()
      return s.peers
    }

    func (s *Session) OnClose(f func()) {
      s.onCloseHandler = f
    }

发布和订阅.
发布Publish的颗粒度比较细,让会话中的其他人订阅Router.
Subcribe订阅颗粒度较粗,是让会话中的其他人订阅某个人.
Subcribe还做了一个datachannel的连接.

    func (s *Session) Publish(router Router, r Receiver) {
      s.mu.RLock()
      defer s.mu.RUnlock()

      for pid, p := range s.peers {
        // Don't sub to self
        if router.ID() == pid {
          continue
        }

        log.Infof("Publishing track to peer %s", pid)

        if err := router.AddDownTracks(p.subscriber, r); err != nil {
          log.Errorf("Error subscribing transport to router: %s", err)
          continue
        }
      }
    }

    // Subscribe will create a Sender for every other Receiver in the session
    func (s *Session) Subscribe(peer *Peer) {
      s.mu.RLock()
      defer s.mu.RUnlock()

      subdChans := false
      for pid, p := range s.peers {
        if pid == peer.id {
          continue
        }
        err := p.publisher.GetRouter().AddDownTracks(peer.subscriber, nil)
        if err != nil {
          log.Errorf("Subscribing to router err: %v", err)
          continue
        }

        if !subdChans {
          for _, dc := range p.subscriber.channels {
            label := dc.Label()
            n, err := peer.subscriber.AddDataChannel(label)

            if err != nil {
              log.Errorf("error adding datachannel: %s", err)
              continue
            }

            n.OnMessage(func(msg webrtc.DataChannelMessage) {
              s.onMessage(peer.id, label, msg)
            })
          }
          subdChans = true

          peer.subscriber.negotiate()
        }
      }
    }

在订阅中,datachannel连接好之后,通过DataChannel.OnMessage设置了消息处理函数.

    func (s *Session) onMessage(
      origin, label string, msg webrtc.DataChannelMessage) {
      s.mu.RLock()
      defer s.mu.RUnlock()
      for pid, p := range s.peers {
        if origin == pid {
          continue
        }

        dc := p.subscriber.channels[label]
        if dc != nil && dc.ReadyState() == webrtc.DataChannelStateOpen {
          if msg.IsString {
            if err := dc.SendText(string(msg.Data)); err != nil {
              log.Errorf("Sending dc message err: %v", err)
            }
          } else {
            if err := dc.Send(msg.Data); err != nil {
              log.Errorf("Sending dc message err: %v", err)
            }
          }
        }
      }
    }

从代码中可以看出,Session.onMessage是将通过datachannel将消息广播给其他参与者.

    func (s *Session) AddDatachannel(owner string, dc *webrtc.DataChannel) {
      label := dc.Label()

      s.mu.RLock()
      defer s.mu.RUnlock()

      s.peers[owner].subscriber.channels[label] = dc

      dc.OnMessage(func(msg webrtc.DataChannelMessage) {
        s.onMessage(owner, label, msg)
      })

      for pid, p := range s.peers {
        if owner == pid {
          continue
        }
        n, err := p.subscriber.AddDataChannel(label)

        if err != nil {
          log.Errorf("error adding datachannel: %s", err)
          continue
        }

        pid := pid
        n.OnMessage(func(msg webrtc.DataChannelMessage) {
          s.onMessage(pid, label, msg)
        })

        p.subscriber.negotiate()
      }
    }

Session.AddDatachannel是给指定参与者指定一个datachannel,
并让其他参与者的datachannel都和指定参与者的datachannnel相连.

从功能上看, AddDatachannel+Publish=Subcribe.

## peer.go

对外暴露的类型:

    type SessionProvider interface {
      GetSession(sid string) (*Session, WebRTCTransportConfig)
    }

SFU类型就实现了这个接口.因为Peer对象是需要获取会话信息的,正好可以利用这个接口.

    type Peer struct {
      sync.Mutex
      id         string
      session    *Session
      provider   SessionProvider
      publisher  *Publisher
      subscriber *Subscriber

      OnOffer                    func(*webrtc.SessionDescription)
      OnIceCandidate             func(*webrtc.ICECandidateInit, int)
      OnICEConnectionStateChange func(webrtc.ICEConnectionState)

      remoteAnswerPending bool
      negotiationPending  bool
    }

Peer表示的是一对p2p连接.

    func NewPeer(provider SessionProvider) *Peer {
      return &Peer{
        provider: provider,
      }
    }

构造之后就可以发送信令了. 使用时,构成参数可以使用SFU实例.

Peer提供了如下方法,对应着Peer端的流程:

- Join 使用会话id来初始化一个Peer,会带一个sdp offer
- Answer 处理一个标准的额sdp offer,返回sdp answer
- SetRemoteDescription 收到一个sdp answer后,调用此方法处理
- Trickle 处理ice候选
- Close 关闭Peer

下面来一一看看

    func (p *Peer) Join(
      sid string,
      sdp webrtc.SessionDescription) (*webrtc.SessionDescription, error) {

      if p.publisher != nil {
        log.Debugf("peer already exists")
        return nil, ErrTransportExists
      }

      pid := cuid.New()
      p.id = pid
      var (
        cfg WebRTCTransportConfig
        err error
      )

      // 获取会话信息和传输对象的信息
      p.session, cfg = p.provider.GetSession(sid)

      // 构造一个新的Subsciber,这个下一步分析
      p.subscriber, err = NewSubscriber(pid, cfg)
      if err != nil {
        return nil, fmt.Errorf("error creating transport: %v", err)
      }

      // 构造一个新的Publisher,这个下一步分析
      p.publisher, err = NewPublisher(p.session, pid, cfg)
      if err != nil {
        return nil, fmt.Errorf("error creating transport: %v", err)
      }

      // 设置NegotiationNeeded处理
      p.subscriber.OnNegotiationNeeded(func() {
        p.Lock()
        defer p.Unlock()

        if p.remoteAnswerPending {
          p.negotiationPending = true
          return
        }

        log.Debugf("peer %s negotiation needed", p.id)
        offer, err := p.subscriber.CreateOffer()
        if err != nil {
          log.Errorf("CreateOffer error: %v", err)
          return
        }

        p.remoteAnswerPending = true
        if p.OnOffer != nil {
          log.Infof("peer %s send offer", p.id)
          p.OnOffer(&offer)
        }
      })

      // 设置subscriber/publisher的ice处理
      p.subscriber.OnICECandidate(func(c *webrtc.ICECandidate) {
        log.Debugf("on subscriber ice candidate called for peer " + p.id)
        if c == nil {
          return
        }

        if p.OnIceCandidate != nil {
          json := c.ToJSON()
          p.OnIceCandidate(&json, subscriber)
        }
      })

      p.publisher.OnICECandidate(func(c *webrtc.ICECandidate) {
        log.Debugf("on publisher ice candidate called for peer " + p.id)
        if c == nil {
          return
        }

        if p.OnIceCandidate != nil {
          json := c.ToJSON()
          p.OnIceCandidate(&json, publisher)
        }
      })

      p.publisher.OnICEConnectionStateChange(func(s webrtc.ICEConnectionState) {
        if p.OnICEConnectionStateChange != nil {
          p.OnICEConnectionStateChange(s)
        }
      })

      // Peer初始化完成后,添加到会话列表中
      p.session.AddPeer(p)

      log.Infof("peer %s join session %s", p.id, sid)

      // 处理offer,返回answer
      answer, err := p.publisher.Answer(sdp)
      if err != nil {
        return nil, fmt.Errorf("error setting remote description: %v", err)
      }

      log.Infof("peer %s send answer", p.id)

      // 同时新建的Peer会订阅其他参与者的流
      p.session.Subscribe(p)

      return &answer, nil
    }

所有的推拉流,只有先执行Join之后才能进行.

    func (p *Peer) Answer(
      sdp webrtc.SessionDescription) (*webrtc.SessionDescription, error) {

      if p.subscriber == nil {
        return nil, ErrNoTransportEstablished
      }

      log.Infof("peer %s got offer", p.id)

      // 如果协商状态不是初始状态,就忽略此次sdp offer处理请求
      if p.publisher.SignalingState() != webrtc.SignalingStateStable {
        return nil, ErrOfferIgnored
      }

      answer, err := p.publisher.Answer(sdp)
      if err != nil {
        return nil, fmt.Errorf("error creating answer: %v", err)
      }

      log.Infof("peer %s send answer", p.id)

      return &answer, nil
    }

    func (p *Peer) SetRemoteDescription(sdp webrtc.SessionDescription) error {
      if p.subscriber == nil {
        return ErrNoTransportEstablished
      }
      p.Lock()
      defer p.Unlock()

      log.Infof("peer %s got answer", p.id)
      if err := p.subscriber.SetRemoteDescription(sdp); err != nil {
        return fmt.Errorf("error setting remote description: %v", err)
      }

      p.remoteAnswerPending = false

      if p.negotiationPending {
        p.negotiationPending = false
        go p.subscriber.negotiate()
      }

      return nil
    }

这里设置远端sdp,用的是subscriber,这块后续需要详细看看.

    func (p *Peer) Trickle(candidate webrtc.ICECandidateInit, target int) error {
      if p.subscriber == nil || p.publisher == nil {
        return ErrNoTransportEstablished
      }
      log.Infof("peer %s trickle", p.id)
      switch target {
      case publisher:
        if err := p.publisher.AddICECandidate(candidate); err != nil {
          return fmt.Errorf("error setting ice candidate: %s", err)
        }
      case subscriber:
        if err := p.subscriber.AddICECandidate(candidate); err != nil {
          return fmt.Errorf("error setting ice candidate: %s", err)
        }
      }
      return nil
    }

处理ice候选,通过target来选择publisher或subscriber.

    func (p *Peer) Close() error {
      if p.session != nil {
        p.session.RemovePeer(p.id)
      }
      if p.publisher != nil {
        p.publisher.Close()
      }
      if p.subscriber != nil {
        if err := p.subscriber.Close(); err != nil {
          return err
        }
      }
      return nil
    }

Close会清理会话的参与者列表,也会清理publisher和subscriber.

## publisher.go

对外暴露的是Publisher类型:

    type Publisher struct {
      id string
      pc *webrtc.PeerConnection

      router     Router
      session    *Session
      candidates []webrtc.ICECandidateInit

      onTrackHandler                    func(*webrtc.TrackRemote, *webrtc.RTPReceiver)
      onICEConnectionStateChangeHandler atomic.Value // func(webrtc.ICEConnectionState)

      closeOnce sync.Once
    }

在Publisher中包含了webrtc.PeerConnection.ice候选缓存,
同时还支持轨道处理/ice连接状态处理.

Router封装了一个轨道的rtp/rtcp,下一步分析这个.

    func NewPublisher(session *Session, id string,
      cfg WebRTCTransportConfig) (*Publisher, error) {

      // 构造webrtc.MediaEngine对象
      // 具体的分析在构造函数下方
      me, err := getPublisherMediaEngine()
      if err != nil {
        log.Errorf("NewPeer error: %v", err)
        return nil, errPeerConnectionInitFailed
      }

      // 构造一个webrtc api对象
      // 这里的写法非常有意思,参考了option模式
      api := webrtc.NewAPI(webrtc.WithMediaEngine(me), webrtc.WithSettingEngine(cfg.setting))

      // 之后通过api来构造一个PeerConnection
      pc, err := api.NewPeerConnection(cfg.configuration)

      if err != nil {
        log.Errorf("NewPeer error: %v", err)
        return nil, errPeerConnectionInitFailed
      }

      p := &Publisher{
        id:      id,
        pc:      pc,
        session: session,
        router:  newRouter(pc, id, cfg.router),
      }

      pc.OnTrack(func(track *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
        log.Debugf("Peer %s got remote track id: %s \
          mediaSSRC: %d rid :%s streamID: %s",
          p.id, track.ID(), track.SSRC(), track.RID(), track.StreamID())
        if r, pub := p.router.AddReceiver(receiver, track); pub {
          p.session.Publish(p.router, r)
        }
      })

      pc.OnDataChannel(func(dc *webrtc.DataChannel) {
        if dc.Label() == apiChannelLabel {
          // terminate api data channel
          return
        }
        p.session.AddDatachannel(id, dc)
      })

      pc.OnICEConnectionStateChange(
        func(connectionState webrtc.ICEConnectionState) {
        log.Debugf("ice connection state: %s", connectionState)
        switch connectionState {
        case webrtc.ICEConnectionStateFailed:
          fallthrough
        case webrtc.ICEConnectionStateClosed:
          log.Debugf("webrtc ice closed for peer: %s", p.id)
          p.Close()
        }

        if handler, ok := p.onICEConnectionStateChangeHandler.Load().(
          func(webrtc.ICEConnectionState)); ok && handler != nil {

          handler(connectionState)
        }
      })

      return p, nil
    }

在Publisher的构造中,第一个就是构造一个webrtc.MediaEngine.
构造的过程在mediaengine.go中,简单列一下:

- 构造一个空的webrtc.MediaEngine
- 注册opus 111
- 注册视频编码
  - vp8 96
  - vp9 profile-id=0 98
  - vp9 profile-id=1 100
  - h264
    - level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f 102
    - level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42001f 127
    - level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f 125
    - level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42e01f 108
    - level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640032 123
- 设置音视频的扩展头
