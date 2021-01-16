# sfu的main入口

入口代码:

    if !parse() {
      showHelp()
      os.Exit(-1)
    }

parse()是解析参数,解析成功会调用load().

    // 检查文件是否存在
    _, err := os.Stat(file)
    if err != nil {
      return false
    }

load()主要是加载配置文件,加载的方式是通过spf13的viper库,
加载完之后,检查了端口的范围.

回到main函数,加载完配置文件后,初始化日志.

    s := sfu.NewSFU(conf)

新建一个sfu会话.main函数的剩余部分做了两个事:

- 开启一个websocket服务
- 开启一个相关指标查看的http服务

每一个通过websocket连上的用户,都被认为是一个有效用户:

    p := server.NewJSONSignal(sfu.NewPeer(s))
    defer p.Close()

    // NewConn的第一个参数是上下文
    // 第二个参数是ws连接
    // 第三个参数是处理对象,正是json-rpc/server(下一步需要分析的业务逻辑)
    jc := jsonrpc2.NewConn(r.Context(), websocketjsonrpc2.NewObjectStream(c), p)
    <-jc.DisconnectNotify(

这里是将每个ws连接都作为一个peer,在ws上套用了一层jsonrpc2.0.
ws连接断开,相关资源就会被释放掉.
