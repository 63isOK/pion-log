# 认识webrtc

这个是从webrtc.org官网摘录的,写这个系列有两个原因:

1. vpn之便
2. 从不同的视角看下webrtc核心的概念

这个系列的重点是介绍核心概念,所以会对一些基础的东西介绍的多一些.

稍后还会从pion的核心贡献者的思路去看一下.

[传送门](https://webrtc.org/getting-started/overview)

## webrtc api

webrtc的api并举局限于spec中指定的那些,还包含H5的一些其他api.
从高层次来看,webrtc api分两部分:媒体捕获的设备和p2p连接.

媒体捕获的设备:

- 摄像头/麦克风, 通过`navigator.mediaDevices.getUserMedia()`捕获MediaStreams
- 屏幕, 通过`navigator.mediaDevices.getDisplayMedia()`捕获MediaStreams

p2p连接, 由`RTCPeerConnection`接口处理,这个接口负责创建和控制两个peer之间的连接.

## 设备

跟设备相关的操作有:

1. 查询设备, 查询-选择,作为参数传入webrtc的api
2. 监听设备, 对应热插拔场景
3. 媒体约束, 这是对设备输出的约束,分辨率,是否启用3A都是在约束中指定的
4. 本地回放, 这算是一个刚需,特别是会议或在线教育场景

我们称之为设备,是因为实现了`MediaDevices`接口,在web中,webrtc的api能访问摄像头/麦克风,
是因为js中的navigator.mediaDevices对象实现了MediaDevices接口,我们可以直接通过这个对象,
完成以下操作:

1. 列出所有设备
2. 监听设备的热插拔
3. 打开设备,并从中获取媒体流

常用的js写法是这样的`navigator.mediaDevices.getUserMedia(constraints)`,
其中navigator.mediaDevices就是设备对象,getUserMedia就是获取媒体流,其中的参数就是约束.
ps: getUserMedia会触发异步请求,过程中会等待用户授权,整个过程中导致失败的情况非常多:
用户不授权;找不到匹配的设备;匹配的设备被占用等.

由于安全和隐私的问题,api中是拿不到设备的设备id和设备标签(设备名)的.