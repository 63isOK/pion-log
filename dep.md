# 依赖分析

go.mod 如下:

    require (
      github.com/pion/datachannel v1.4.21
      github.com/pion/dtls/v2 v2.0.4
      github.com/pion/ice/v2 v2.0.13
      github.com/pion/interceptor v0.0.5
      github.com/pion/logging v0.2.2
      github.com/pion/quic v0.1.4
      github.com/pion/randutil v0.1.0
      github.com/pion/rtcp v1.2.6
      github.com/pion/rtp v1.6.1
      github.com/pion/sctp v1.7.11
      github.com/pion/sdp/v3 v3.0.3
      github.com/pion/srtp/v2 v2.0.0-rc.3
      github.com/pion/transport v0.12.0
      github.com/sclevine/agouti v3.0.0+incompatible
      github.com/stretchr/testify v1.6.1
      golang.org/x/net v0.0.0-20201201195509-5d6afe98e0b7
    )

属于pion自己开发的有:

- datachannel
- dtls
- ice
- interceptor
- logging
- quic
- randutil
- rtcp
- rtp
- sctp
- sdp
- srtp
- transport

[依赖图](/resource/dep.png)

说明:

- 粉底是第三方库,天蓝底是pion的库
- 红色框中的randutil/testify/logging,是基础库,很多库都依赖这3个库

分析:

- 核心都是以x/net库为中心,一步步扩展
- 直接依赖x/net的有4个库,transport/mdns/ice/dtls
  - 其中mdns/ice/dtls都依赖transport
  - ice依赖dtls/mdns
  - 总的来说.ice依赖mdns/dtls,她们都依赖transport
  - 依赖x/net的库,要么使用了网络连接,要么使用了网络工具库的功能
- transport作为传输对象的封装,有以下库使用
  - quic, quic协议的实现
  - dtls, udp 安全传输协议的实现
  - srtp, 安全rtp传输协议的实现
  - ice, p2p连接解决方案的实现
  - turn, p2p中继协议的实现
  - mdns, 多播dns协议的实现
  - datachannel/sctp, webrtc数据传输通道的实现
  - transport作为传输对象的封装,屏蔽了底层网络传输细节
    - 让webrtc上层诸多传输协议复用,大大提高了效率
- 按webrtc功能分
  - datachannel/sctp 对应webrtc datachannel
  - srtp/rtp/rtcp 对应webrtc媒体数据的传输
  - ice 对应p2p连通性解决方案
  - dlts 对应udp安全传输

源码阅读顺序:

- 基础公共库
  - randutil
  - testify
  - logging
- 基础库
  - x/net
  - transport
  - dtls
- p2p
  - stun/turn
  - ice
- rtp
  - rtp/rtcp/srtp
  - interceptor
- sdp
- 其他功能
  - mdns
  - datachannel/sctp
  - agoutil
  - quic
