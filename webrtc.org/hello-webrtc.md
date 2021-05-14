# 认识webrtc

这个是从webrtc.org官网摘录的,写这个系列有两个原因:

1. vpn之便
2. 从不同的视角看下webrtc核心的概念

稍后还会从pion的核心贡献者的思路去看一下.

## webrtc api

webrtc的api并举局限于spec中指定的那些,还包含H5的一些其他api.
从高层次来看,webrtc api分两部分:媒体捕获的设备和p2p连接.

媒体捕获的设备:

- 摄像头/麦克风, 通过`navigator.mediaDevices.getUserMedia()`捕获MediaStreams
- 屏幕, 通过`navigator.mediaDevices.getDisplayMedia()`捕获MediaStreams

p2p连接, 由`RTCPeerConnection`接口处理,这个接口负责创建和控制两个peer之间的连接.