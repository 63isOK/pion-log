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

js中用navigator.mediaDevices实现了设备接口,枚举是enumerateDevices()方法;
打开是getUserMedia(),获取的媒体流可直接有H5的video播放,设备变化的事件是devicechange.

其中getUserMeida的参数是约束,其实是实现了MediaStreamConstraints接口.
这个约束是用于匹配最佳设备.约束可以很详细,也可以很宽松.也可以指定一个功能的使能,eg:aec.

对于播放,实际情况中一般会指定video的3个属性: autoplay 表示自动播放;
playsinline 在移动端表示小窗支持; controls="false" 表示不显示播放控件.

以下是一个包含设备所有操作的例子:

```html
<html>

<head>
  <title>我的第一个 HTML 页面</title>
  <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
</head>

<body>
  <p>body 元素的内容会显示在浏览器中。</p>
  <p>title 元素的内容会显示在浏览器的标题栏中。</p>
  <select id="availableCameras">
  </select>
  <video id="localVideo" autoplay playsinline controls="false" />
</body>

<script>

  // query devices
  async function queryDevices(type) {
    const devices = await navigator.mediaDevices.enumerateDevices();
    return devices.filter(device => device.kind === type)
  }

  console.log('cameras found:', queryDevices('videoinput'))
  console.log('mic found:', queryDevices('audioinput'))

  // NOTE: promise写法
  // navigator.mediaDevices.enumerateDevices()
  //   .then(function (devices) {
  //     devices.forEach(function (device) {
  //       console.log(device.kind + ":" + device.label + " id=" + device.deviceId);
  //     });
  //   })
  //   .catch(function (err) {
  //     console.log(err.name + ":" + err.message);
  //   });

  // device change event

  function updateCameraList(cameras) {
    const listElement = document.querySelector('select#availableCameras');
    listElement.innerHTML = '';
    cameras.then(function (devices) {
      devices.forEach(function (device) {
        const cameraOption = document.createElement('option');
        cameraOption.label = devices.label;
        cameraOption.value = devices.deviceId;
        listElement.appendChild(cameraOption);
      });
    });
  }

  const currentList = queryDevices('videoinput');
  updateCameraList(currentList);

  navigator.mediaDevices.addEventListener('devicechange', event => {
    const newList = queryDevices('videoinput');
    updateCameraList(newList);
  })

  // open divices

  const openDevices = async (constraints) => {
    return await navigator.mediaDevices.getUserMedia(constraints);
  }

  try {

    const stream = openDevices({
      'video': true,
      'audio': true,
      'echoCancellation': true
    });

    console.log('got MediaStream', stream);

    const videoElement = document.querySelector('video#localVideo');
    stream.then(function (streams) {
      videoElement.srcObject = streams;
    });

  } catch (error) {

    console.error('error accessing media devices.', error);
  }
</script>

</html>
```