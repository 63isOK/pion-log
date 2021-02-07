# 基于浏览器的app中的实时协议概览

发布日期 2021/01  
发布人 google  

这个rfc是仅仅是描述了实时协议(real time protocols)套件里面的内容和概览,
并不是如何使用这些套件.

这个rfc是webrtc标准规范的起点,通过这个rfc可以找到所有webrtc构建的其他组件,
并维护所有其他组件的跟踪信息.

这个rfc是个声明式的,内容中并不指定任何协议.

## 介绍

以前的路:

- 互联网需要实时交互,特别是音视频
- 早期,实时音视频的障碍是:网络/硬件/自定义软件,代价很大
- 随后,带宽/硬件都更上了,普通电脑也能用实时音视频了
- 还剩以下障碍没解决:
	- 交互的通信协议没有标准
	- 缺少唯一识别系统
- 通用的解决方案,非常难
- 随后几年,web app盛行,web平台拥有同一的基础设置
- 通常都是通过插件来实现,直到H5的出现,让基础设置成了浏览器的标准

现在:

- 本memo(本rfc)描述了两块:
	- 访问和控制js api
	- 通过这些api构建一个功能集,通过功能集来完成实时音视频的交互
- 最终的这些协议套件可以支撑rfc7478中规定的webrtc用例
- 另一方面,w3c等组织在积极推动在h5/非h5中的api标准化

本mome重点关注交互的协议和子协议.

在信令方面,一般基于tls加密,具体协议由app指定.
网络元素的识别(就是对应上面的唯一识别系统)有两种方案:
rfc3361中终端向sip服务请求sdp,走的是dhcp;或sip的algs应用层网关来处理,
后一种方案并不适合我们所说的信令.
这种终端协作的网络,有个更好的方式:通过turn服务,这个在rfc8155中定义的.
随着终端数的增加,就不能用一些专用的硬件,这会降低一些效率,
例如跟踪或qos,rfc8837针对这点提出了qos的新方案.

另外针对ice,以前的老版本是rfc5245,针对webrtc,提出了rfc8445,
ice协商的机制也用rfc8838来跟踪.

ps:这种将webrtc相关技术集中放在一起的方式比以前好多了,赞赞赞.

## 原理和术语

### 本memo的目标

webrtc协议规范(spec)的目标是指定一系列协议,
如果这些协议全部实现了,那么就能和另一个实现进行实时音视频交互,
包括其他数据的交互.

本mome的重点在于指出这些协议,而不是对这些协议进行细化,细化属于其他文档.

### api和协议的关系

webrtc现在包含两个部分,每个部分都包含多个文档:

- 协议规范spec,归ietf推进
- js api规范spec,由w3c维护

两者合在一起,目标是实现实时音视频互动.
协议规范spec并不假定所有的实现都实现了api,交互的一方不需要关心是浏览器实现的api,
还是其他实现.
协议和api的协作是用于说明:特征和选项需要执行哪些api.

以下是一些术语,并未包含所有webrtc的术语,未包含的在子协议文档中.

- Agent,未定义
- Browser,与"交互式用户代理"同义,白话文就是实现了webrtc 协议和api的浏览器
- Data Channel, webrtc endpoints之间的抽象概念
	- 通过数据通道可以传输数据
	- 两个endpoint之间可以多个数据通道
- ICE Agent, rfc8445 ice协议的一个实现
	- ice代理可以是sdp代理,也可以不用sdp,而用jingle
- Interactive, 多方之间的交流,业务上称交互
	- 一方的行为会引起另一方的反应,行动发起方可以观察到这个反应
	- 行动/反应/观察是有序的,且总需时间不超过几百毫秒
- Media, 音视频内容
- Media Path, 媒体数据从webrtc endpoint之间流经的路径
- Protocol, 数据单元集的规范
	- 定义了表现形式/传输规则/语义
	- 通常协议是systems之间进行
- Real-Time Media, 媒体的生成时间和显示时间非常接近
	- 生成和显示不超过几百毫秒
	- 实时媒体用于支撑交互式交流
- SDP Agent, 对sdp offer/answer模型的一个实现
- Signaling, 信令
	- 按序建立/管理/控制 media paht/data path过程中的交流
- Signaling Path, 信令路径
	- 参与信令的实体之间,用于传输信令的交流通道
	- 信令路劲中的实体可能比媒体路径中的实体多
- WebRTC Browser, webrtc浏览器
	- 和上面的Browser是一个意思
	- 同时也被称为WebRTC User Agent或WebRTC UA
	- webrtc浏览器同时实现协议和api
- WebRTC Non-Browser, 非浏览器的webrtc实现
	- 实现了webrtc协议,但声称实现了js api
	- 也就是非浏览器实现
	- 也叫WebRTC device(webrtc设备),WebRTC native application(webrtc原生应用)
- WebRTC Endpoint, webrtc浏览器或者是webrtc设备
	- 实现了webrtc协议
- WebRTC-Compatible Endpoint, webrtc的兼容endpoint
	- 这类endpoint可以和webrtc endpoint成功交流
	- 但不满足某些webrtc endpoint的要求
	- 使用上会有些限制,不在本mome考虑范围内
- WebRTC Gateway, 一个webrtc兼容endpoint
	- 可以将媒体流量调度到其他非webrtc实体上

所有支持webrtc的浏览器都是webrtc endpoint.
webrtc device通常是非js语言实现的api,webrtc device同样要考虑安全问题.

## 架构和功能组

首先,web app中,rtc模型是需要后台服务一起来提供服务的.
这意味着需要两个重要的接口需要规范:

- 浏览器在没有任何中间服务的情况下,可以彼此对话
- 给js程序提供api,以利用浏览器的功能

web app模型如下:

		/*************************************************
		 *		 +------------------------+  On-the-wire
		 *		 |                        |  Protocols
		 *		 |      Servers           |--------->
		 *		 |                        |
		 *		 |                        |
		 *		 +------------------------+
		 *								 ^
		 *								 |
		 *								 |
		 *								 | HTTPS/
		 *								 | WebSockets
		 *								 |
		 *								 |
		 *	 +----------------------------+
		 *	 |    JavaScript/HTML/CSS     |
		 *	 +----------------------------+
		 *Other  ^                 ^ RTC
		 *APIs   |                 | APIs
		 *	 +---|-----------------|------+
		 *	 |   |                 |      |
		 *	 |                 +---------+|
		 *	 |                 | Browser ||  On-the-wire
		 *	 | Browser         | RTC     ||  Protocols
		 *	 |                 | Function|----------->
		 *	 |                 |         ||
		 *	 |                 |         ||
		 *	 |                 +---------+|
		 *	 +---------------------|------+
		 *												 |
		 *												 V
		 *										Native OS Services
		 *************************************************/

通过浏览器api可以为js app提供https/websocket能力,
webrtc并没有限制使用何种协议.
常见的web app部署模式就是梯形模式:

		/*************************************************************
		 *			 +-----------+                  +-----------+
		 *			 |   Web     |                  |   Web     |
		 *			 |           |                  |           |
		 *			 |           |------------------|           |
		 *			 |  Server   |  Signaling Path  |  Server   |
		 *			 |           |                  |           |
		 *			 +-----------+                  +-----------+
		 *						/                                \
		 *					 /                                  \ Application-defined
		 *					/                                    \ over
		 *				 /                                      \ HTTPS/WebSockets
		 *				/  Application-defined over              \
		 *			 /   HTTPS/WebSockets                       \
		 *			/                                            \
		 *+-----------+                                +-----------+
		 *|JS/HTML/CSS|                                |JS/HTML/CSS|
		 *+-----------+                                +-----------+
		 *+-----------+                                +-----------+
		 *|           |                                |           |
		 *|           |                                |           |
		 *|  Browser  |--------------------------------|  Browser  |
		 *|           |          Media Path            |           |
		 *|           |                                |           |
		 *+-----------+                                +-----------+
		 *************************************************************/

从上面可以看出,信令路径和媒体路径是独立的.如果称媒体路径是底层路径,
对应的,信令路径就是高层路径.
媒体路径要符合webrtc协议规范spec,信令路径是可以根据需求进行修改/转换/操纵.

如果图上的两个web server不是同一个实体,那么web server之间的信令机制要达成一致.
要达到一致,sip协议或xmpp都是可选的.

client-server之间的传输协议,或者web server之间的传输协议,并不在webrtc协议的规则中.

功能组,就是浏览器提供的一些功能:

- Data transport,数据传输
	- tcp还是udp,实体之间安全建立连接的方法
	- 决定合适发送数据的功能
	- 拥塞控制,带宽估计等
- Data framing,数据帧化
	- rtp/sctp/dtls以及其他可作为容器的数据格式
	- 封装格式对应的功能,并确保数据丢额机密性和完整性
- Data formats, 数据格式
	- systems之间传输数据的编码器规范/格式规范/功能规范
	- 音视频编解码,数据和共享文档的格式都属于Data formats
	- 为了利用数据格式,需要一种描述方法(eg:sdp)
- Connection management,连接管理
	- 建立连接/协商数据格式/会话期间变更数据格式
	- sdp/sip, jingle/xmpp属于此类
- Presentation and control, 呈现和控制
	- 要确保不出现异常情况
	- 发言权控制/屏幕布局/受语音激活的图像切换
- Local system support functions,本地支持的功能
	- 回声消除
	- 本地身份认证和授权机制
	- 操作系统访问控制
	- 本地录制

将功能按功能组切分,易于创新.

数据传输/数据帧化/数据格式是媒体传输基础设置,
连接管理/呈现和控制/本地功能是媒体服务.
媒体传输基础设置标准化,便于访问;媒体服务就是各家各样,
依据实际需求来选择.

一个完整的可交互服务,至少需要前5个功能组.

## 数据传输

数据传输指的是通过网卡进行数据的收发.
需要选择网络层的地址,如果需要,还要使用中间件(eg:turn),
中间件不修改数据.

整个过程中,还包含拥塞控制/重传/有序传递的功能.

数据传输的详细定义在rfc8835(tranposrt for webrtc).

## 数据帧化和安全

媒体传输中的rtp在rfc3550中定义,srtp在rfc3711中定义.

rtp/srtp的注意事项在rfc8834中定义.
webrtc用例的安全注意事项在rfc8826,
最终的安全功能在rfc8827中.

非rtp格式传输时的安全注意事项在rfc8831中定义,
单独建立数据通道的在rfc8832.
webrtc endpoint需要支持这两种.

## 数据格式

webrtc规定了一些音视频编码,保证按此标准的webrtc endpoint可以正常交互,
也保留了很多编解码器,供实现者使用.

rfc7874定义了音频编码和处理要求,rfc7742定义了视频的.

## 连接管理

连接的建立/协商/关闭,他们的方法/机制/要求包含很多东西,
包含很多交互性和扩展.

有3条原则:

- webrtc媒体协商机制是sip中的sdp offer/answer机制
	- rfc3264
	- 通过这个机制可以在sip和媒体协商之间建立信令网关
- 在媒体网关的情况下,在老sip设备之间建立网关
	- 前提是sip设备支持ice/rtp/sdp/编码/安全机制
	- 这样还需要一个信令网关来转换web信令和sip信令
- 为新编解码器指定sdp时,不需要其他标准化就能在浏览器中使用
	- 可能会有新的sdp参数,但不需要改变api
	- 一旦浏览器支持了一种新的编解码器,老web app自动拥有这种能力,无需修改代码

rfc8829描述了webrtc的一些抉择.

webrtc endpoint必须实现rfc8829中描述的网络层,
网络层包括(rfc8843的bundle,rfc5761的rtcp-mux,rfc8838的trickle ice),
rfc8829中的api功能并不一定需要实现.

## 呈现和控制

控制最重要的是用户对浏览器与输入输出设备和通信通道交互的控制.
音视频数据/其他数据,发到哪儿,为什么要发,用户必须清楚.
这很大程度上是浏览器/操作系统/用户界面的本地化功能.

这需要调用api:

- webrtc api : [https://www.w3.org/TR/webrtc/](https://www.w3.org/TR/webrtc/)
- media capture and streams api : [https://www.w3.org/TR/mediacapture-streams/](https://www.w3.org/TR/mediacapture-streams/)

## 本地系统支持的功能

这些功能会影响实现的质量,最终会影响用户体验,
这些功能不需要协调.整个系统只需要指出需要这些功能,不需要指出这些功能的实现方式,
例如回声消除/音量控制/摄像头设备管理/对焦/缩放/平移控制/倾斜控制等等.

这些功能,一般视具体的业务场景的需求而需要.例如:

- 回声消除应足够好,要将回声抑制在可感知水平以下
- 要注重隐私,例如:本地参与者应该明确知道谁在远程控制摄像机,并能撤销许可
- agc,自动增益,应将说话声控制在一个合理的分贝dB范围内

rfc7874定义了音频处理.
aec/agc的控制api在media capture and streams api.

最后附上本mome提到的相关协议:

![webrtc概览](/rfc/webrtc.png)
