## webrtc中的数据传输

发布日期 2021/01  
发布人 google  

这是6大功能组的第一个功能组.

这个memo描述了webrtc中数据传输的协议,包括和中间件的交互协议,
中间件包括:防火墙/中继/nat等.

## 介绍

webrtc视一个协议套件,目的是:在浏览器之间或浏览器和其他实体之间,进行实时多媒体交换.

rfc7656定义了术语:rtp source(rtp源).

本memo还需要遵循rfc8826/rfc8827的安全.

本memo描述的适用所有webrtc endpoint,如果仅适用浏览器,则会特别标出.

## 传输和中间件规范

### 系统提供的接口

本memo假定系统已经提供了以下协议,因为以下协议是webrtc协议实现的基础:

- udp,rfc0768
- tcp,rfc0793

tcp/udp的ipv4/ipv6都需要支持.当多个媒体类型被服用时,也假设了udp的dscp能被启用.
因为dscp差分服务点时本地配置,所以本memo都会假设dscp会被置0,会被修改.

ps:国内实际情况是:dscp都会被置0.

如果无法访问tcp/udp能力,就无法支持一致的webrtc endpoints.
本memo不假设实现可以访问icmp/原始ip.

webrtc endpoint可能会用到一下协议:

- rfc8656,turn
- rfc5389,stun
- rfc8845,ice
- rfc8846,tls
- rfc6347,dtls

### 有能力支持ipv4和ipv6

浏览器必须支持ipv4和ipv6.
如果使用到了中继turn,而turn只支持一种(4或6),也需要支持这种协商格式.

rfc8421多宿主,ip v4 v6双协议栈的ice指南协议必须支持.

### 临时ipv6地址的使用

rfc6724指出,应该优先使用ipv6临时地址,而不是永久地址,
ipv6临时地址是在rfc4941中定义的.

虽然很多规则要求使用临时地址来增强隐私性,但ice将收集的地址交给应用程序,
所以就有了以下规则:

如果webrtc endpoint在收集ipv6的地址时,如果有临时地址和永久地址都可用,
那么永久地址就会被丢弃;如果有部分临时地址被标记了"弃用",
webrtc endpoint就不会使用这些临时地址,除非这个临时地址正在使用中.

### 中间件相关的功能

中间件处理的最重要的是ice,rfc8445协议必须实现.

如果遇到中继场景,rfc5128定义穿透nat的p2p状态,rfc8656定义了中继.

浏览器需要支持stun/turn.
stun/turn还存在一些问题,eg:服务发现和管理,
rfc8155定义了turn服务的自动发现;
[return](https://tools.ietf.org/html/draft-ietf-rtcweb-return-02)
定义了turn的递归封装,以实现webrtc的连接性和隐私.

有时,防火墙是阻止所有udp流量的,此时turn必须支持tcp模式,
考虑到安全,基于tcp的tls的中继模式也是需要支持的.

turn要同时支持ipv4/ipv6.

rfc6062定义了tcp的中继候选者.

tcp候选出现的场景非常少:

- 只有双方都使用tcp建立连接的情况下,才会使用tcp候选
- 双方使用turn tcp候选来建立udp中继以连接到各自的中继服务器
- webrtc endpoint使用tcp会获得更大的性能(eg:使用udp会有行头阻塞)

同样的rfc6544定义了tcp候选在ice中的使用.

如果使用tcp连接,rfc4571定义了rtp帧的规范,
包括rtp包/dtls承载数据通道包/stun连接检查数据包.

rfc5389的第11节定义了备用服务机制.

webrtc endpoint 应该支持通过http代理来访问互联网,如果此特征不支持,
那么就需要包含ALPN头,这个是在rfc7639中定义的.
rfc7231定义了http1.1的语义和内容,rfc7235定义了http1.1的认证.
