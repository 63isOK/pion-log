# 项目结构分析

子目录有3个

## cmd

里面提供了额外的信令服务,有grpc的,有json-rpc的,
这里可以定制更多业务逻辑.

## examples

提供了对sfu的基本测试demo

## pkg

这里面提供了sfu的功能.

buffer里包含了一些打桩点和对webrtc的扩展;
sfu提供了多webrtc节点之间的分发功能;
stats提供了监控.

## 分析流程

先看json-rpc下的sfu服务入口,
了解整个程序跑器来后,熟悉监控.

其次分析信令业务逻辑.

最后分析sfu的流程和架构,分析监控流程.
