# rfc8826 安全考虑

发布日期 2021/01  
发布人 mozilla

本文会定义webrtc的威胁模型,并分析模型中的安全问题.

ps:8825作为webrtc协议家族的介绍,随后的8826(7)就对安全方面进行了解释,
足以说明标准对安全的重视.

## 介绍

RTCWEB工作组标准化了两个浏览器之间实时交互协议,这个协议也就是rfc8825说的WebRTC协议,
基于WebRTC协议的应用场景主要有3:音视频呼叫/web会议/直接的数据传输.
和传统的实时交互系统不一样的是(eg:在线电话rfc3261):WebRTC交互有web server控制:

    /********************************
    *           +----------------+
    *           |                |
    *           |   Web Server   |
    *           |                |
    *           +----------------+
    *               ^        ^
    *               /          \
    *     HTTPS   /            \   HTTPS
    *       or   /              \   or
    * WebSockets /                \ WebSockets
    *           v                  v
    *       JS API              JS API
    * +-----------+            +-----------+
    * |           |    Media   |           |
    * |  Browser  |<---------->|  Browser  |
    * |           |            |           |
    * +-----------+            +-----------+
    *     Alice                     Bob
    *************************************************/

这是最简单的模型,web server充当了webrtc的信令服务,不管执行逻辑是在浏览器中的js代码中,
还是在web server的代码中,整个会话的控制是在web server中的.

这里面的挑战比传统的voip系统大得多.最主要的是恶意呼叫.
eg:服务端掌控,那么服务端就能决定何时开始会话,这样就可以在用户不知情的情况下窃听用户,
或直接将呼叫进行录制.如果通过浏览器暴露的api能传递任意数据,那么就可以绕过防火墙,
或发起dos功能.

rfc8827就说明了如何解决这些安全问题.一个成功的系统要能对抗这些威胁.

## 术语

## 浏览器的威胁模型

WebRTC中需要的安全,由浏览器来完成,大牛huang总结了浏览器的核心安全功能:

`用户可以访问任意网站,并能执行网站的脚本`.

即使网站提供的是恶意脚本,浏览器也需要解决安全问题.这点很重要.
WebRTC的设计就考虑到了这点.

web安全模型,在这个模型中,浏览器充当一个tcb(受信计算单元),从服务器拿到的脚本会放在沙箱执行.

攻击者分两种:

- web攻击者,无法控制我们的网络,但能让我们访问她们的网站
- 网络攻击者,能控制我们的网络,(rfc3552定义)

有时网络攻击者也是web攻击者,因为部分传输协议没有提供完整个的保护,从而导致了流量注入.
tls/https能阻止这类攻击,http则不行.

### 本地资源的访问

密码文件/本地文件/摄像头/麦克风,如果从服务端来访问,浏览器会进行严格限制或禁止.
eg:服务端的传给浏览器的脚本有个上传,那么不能上传密码文件,必须用户手动指定文件.

有些文件是浏览器也无法访问的,eg:无法直接执行二进制.

### 同源策略

同源sop,跨源cors,在rfc6455中有定义,同源可以保证服务器a不会通过用户b来攻击服务器c.
sop同源策略保障了每个站点的脚本在独立的沙箱中运行,保持隔离.

### 越过同源sop: cors/websocket/consent

websocket就是典型的cors,作为cors,websocket开始时也需要有个协商验证阶段,
不能上来就直接传递数据.

协商验证概念上很简单:在具体交换数据之前,先来一次握手.
这种方式也容易招到攻击,websocket结合了掩码技术,用来随机生成一些位来让攻击变得更困难.

## WebRTC程序的安全

### 本地设备访问

浏览器可以执行任意站点的脚本.那么呼叫至少需要用户同意,第一个问题就是如何量化"用户同意".

用户需要知道谁在请求访问,访问的数据要到哪儿去.所以连接的身份就是关键.

同意常意味两个方面:同意访问设备;同意将访问的数据通过网络传输出去.
针对前者,需要一个同意机制consent,针对后者,需要关注这些要访问数据的站点.

#### 屏幕贡献的安全问题

屏幕和应用的共享,比访问设备的问题复杂很多.

过度共享是一个问题,由受信任的站点触发共享而不是用户触发,是另一个更严重的问题.

还有一些利用屏幕共享来做坏事的场景.所以需要一个比访问设备更高级别的同意机制.

#### 调用场景和用户期望

- 专属网站
  - 用的次数多,希望有个长期的同意机制
  - 网站可以代替我发起呼叫,可以调试我的设备
- 临时呼叫
  - 一种使用期间的短期同意机制
  - 不允许网站随机激活我的呼叫或激活我的设备

#### 基于源的安全

基于源很危险,授权给某个网站,虽然可随时撤销权限,但窃听的风险依然非常高.

除此之外还有:

- 个人同意,每次都向用户询问调用权限
- 基于被叫方的同意,只允许呼叫特定用户
- 基于密码的同意,只允许给出指定密钥的呼叫

上面几种方式都有缺点(ps:目前用的最多是个人同意,也最不可取).

#### 呼叫页面的安全属性

基于源是防止web攻击,同时也需要考虑防止网络攻击

### 同意机制

如果浏览器不限制web程序访问网络,那浏览器就会作为恶意站点的攻击平台,去攻击站点无法访问的机器,
eg:(nat后面的机器),为了阻止这类攻击以及跨协议攻击,需要流量目标明确同意接收相关流量.
在给定端点验证同意之前,只将同意握手消息发到该端点,其他流量都不要发.

同意机制并未阻止过度使用网络资源,恶意站点可能会利用webrtc来进行dos攻击,大量占用下行带宽,
所以webrtc的拥塞控制就非常有必要,同时要保证公平性,此处是满足用户其他的带宽需求.

webrtc通过4个方面来完善同意机制:

- ice
- masking
- backward compatibility
- ip location privacy

#### ice

之前说到了同意机制需要流量目标明确同意接收相关流量,在流量之前需要有个验证同意的握手阶段,
ice(rfc8445)就是验证流量目标是否希望从发送方接收流量,其中的握手动作就实现了nat打洞.

在不安全的场景下,需要认为所有发起ice的站点都是恶意的,这点很重要.
流量目标需要能验证站点是否是伪造的,在ice中是通过stun事务id来实现的,为了防止伪造,
这个事务id是由浏览器生成的,不是由启动脚本(eg:js脚本)生成,也不能由启动脚本获取,
也不能由诊断接口获取.

上面是保证了站点不是伪造的,ice还需要验证流量目标同意接收.
这点利用stun证书作为会话共享密钥实现,可以阻止恶意站点尝试对服务器的ice尝试,
而这些服务器正好提供了ice服务.
这些stun证书可以被web app程序获取,但也需要流量目标知道并使用,这样stun证书才是有用的.

浏览器还需要有个机制来验证流量目标是否继续希望接收,
rfc7675提供了一个新鲜度的机制来衡量同意的新旧程度.

#### masking

掩码,握手成功之后还是可能会被攻击:srtp+基于中继turn的tcp传输,有可能出现风险.

#### backward compatibility

向后兼容,本节说明为啥最终选用ice.

使用ice和不使用ice的传统方式,她们的要求都是兼容的.这些要求如果减少会带来安全风险.
所有的提议检查(一对候选的连通性检查)都有共同的模式:浏览器向候选流量接收者发送特定消息,
除了这些消息不会发送任何其他流量,直到该消息得到回复,浏览器需要保证"消息和回复"无法被
web app伪造,通常的做法是混入一些秘密值(回显/散列等).

不使用ice时,传统做法有以下两种:

- stun检查(不带ice)
- 利用rtcp的可达性来判断

第二种方式rtcp,是先发几个rtp,利用rtcp的反馈来看连通性,这时会有一个短的攻击窗口,
另外如果流量目标不支持rtcp,就需要使用其他代价更高的解决方案,所以rtcp方案被排除.

第一种stun方式,webrtc断点无法验证流量目标是否同意.

#### ip location privacy

ip隐式,callee(被呼叫方)一旦发送了ice候选,caller(呼叫方)就直到了calee的ip地址,
这些ip地址可能是"服务侧ip"(ice的几种ip地址类型之一),这个地址会显示很多信息,包括位置,
在实现上,可以将ice协商抑制到callee进行answer之后.此外可以通过turn来隐藏位置.

### 通信的安全

sip世界常见问题是通讯安全,通讯双方之间会有一个通道,这个通道对消息的恢复和修改是安全的,
目前可选技术是srtp(rfc3711),dtls(rfc6347),dtls-srtp(rfc5763).

web server除了控制通道,还通过提供页面(js/html)还控制了浏览器上运行的程序(web app),
虽然还需要用户来授权,但用户很难真正明白自己的操作.这样web server可能会有两类攻击:

- 被动攻击
  - 呼叫服务在呼叫期间是无害的,但追溯攻击是指攻击者获得密钥,从而可以访问媒体流
- 主动攻击
  - 同化期间的攻击

下面基于这两类攻击来具体分析

#### 被动攻击

web服务中提供了大量日志和监控,攻击者是有几率可以获取到密钥的,
所以webrtc使用基于公钥的自动交换机制.这种做法在任何通信安全系统都是好主意,
而且这种做法还提供了前向保密fs,呼叫服务和信令通道都可使用这套来进行验证.
具体在rfc4568(安全描述sdes)中.

此外,如果使用端到端密钥,系统就不能提供任何api来访问long-term密钥或访问任何流量密钥.
不然这些api就会被攻击者利用.

#### 主动攻击

这就是中间人攻击,本来是a和b通信,攻击者告诉a我是b,告诉b我是a,实际上攻击者就是中间人,
要防御这点就需要远端端点正面认证,eg:带外密钥/指纹/第三方服务.rfc8827有更详细的说明.

下面具体说下这几种防御方法:

`连续key`

攻击者无法通过公钥生成私钥,所以浏览器可以记录用户的公钥,并在密钥变更时报警,
这种做法在ssh协议(rfc4251)中使用.
只是这种做法在webrtc中用处不大,因为webrtc和web app的优点是不绑定到客户端软件,
用户使用多个浏览器是常有的事.连续key的想法是好的,但效果不行.
另外在webrtc中,peer的身份是调度服务告诉的,总会有一个api告诉浏览器,攻击者还是会利用这点.

`一个短的认证字符串`

zrtp(rfc6189),使用了密钥协商协议的"短身份验证字符串sas",sas是通过用户来比较,
eg:朗读或带外传输,这样避免了中间人攻击,之后可以使用连续key.
但现在的语音克隆让sas的前景堪忧.

`第三方认证`

传统第三方认证pki太麻烦,新一代的基于web身份的认证:oauth(rfc7033);openid;browserid,
webfinger(rfc7033)都可以应用到webrtc中,具体做法都是第三方身份系统将用户和加密密钥绑定,
然后用来验证端点,防止中间人攻击.

`页面访问媒体`

#### 恶意peer

webrtc不会阻止peer将通话进行录制和发布.

### 隐式

匿名

webrtc中可能会有一些持久化标识符:dtls证书,rtcp cname,
所以浏览器需要有机制来重置这些标识符.
ip地址也有可能暴露隐式,详见rfc8828.

浏览器指纹

api的增加会增加浏览器指纹识别的风险.

## 总结

rfc8826主要介绍了3个方面:

- 浏览器的威胁模型,明确哪些该由浏览器做,哪些不能暴露给web app,需要哪些辅助机制
- 同意机制,在不安全的情况下,如何达成一致,为啥选ice来保证握手,为啥用共有公钥来解决过程中的安全
- 安全/隐式,用srtp/dtls/srtp-dtls来保证通道安全,以及如何防止"中间人"这种主动攻击