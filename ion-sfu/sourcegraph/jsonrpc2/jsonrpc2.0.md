# jsonrpc2.0的实现

## 请求 request

Request可代表jsorpc2.0的请求或通知.

    type Request struct {
      Method string           `json:"method"`
      Params *json.RawMessage `json:"params,omitempty"`
      ID     ID               `json:"id"`
      Notif  bool             `json:"-"`

      Meta *json.RawMessage `json:"meta,omitempty"`
    }

Meta字段并不是jsonrpc spec中规定的,而是辅助跟踪上下文的.
Notif字段表示是否是通知.
Params/Meta字段均是已做json序列化的字符串.

这个Request有几个方法:

- MarshalJSON 序列化为json字符串
- UnmarshalJSON 将json字符串反序列化为Request对象
- SetParams/SetMeta 分别对应设置Params/Meta字段

ID也是spec中规定的,可以是字符串/数值/空.
目前此包的实现是不支持ID为

    type ID struct {
      Num uint64
      Str string

      IsString bool
    }

大多数情况下,Num和Str总有一个是非零值,当两者都是零值时,
IsString就是用来区分哪个字段用来充当id.方法如下:

- String 支持打印
- MarshalJSON 序列化
- UnmarshalJSON 反序列化

## 响应 Response

Response仅表示响应,不包含通知.

    type Response struct {
      ID     ID               `json:"id"`
      Result *json.RawMessage `json:"result,omitempty"`
      Error  *Error           `json:"error,omitempty"`

      Meta *json.RawMessage `json:"meta,omitempty"`
    }

Result和Error是只能返回一种.
在出现错误时,有一种错误是特殊的,为了简便,直接忽略:
请求中的ID错误.

Response同样包含几个方法:

- MarshalJSON 序列化为json字符串
- UnmarshalJSON 反序列化为Response对象
- SetResult 设置Result字段

从这里的源码可以看出,Request和Response在序列化和反序列化时,
使用了两种不同的写法,这是作者在展示奇淫技巧.

Response.Error在spec中是有明确规定的:

    type Error struct {
      Code    int64            `json:"code"`
      Message string           `json:"message"`
      Data    *json.RawMessage `json:"data"`
    }

Error的方法:

- SetError 设置Error中的Data
- Error 实现error接口

下面几个是spec中规定的错误

    const (
      CodeParseError     = -32700
      CodeInvalidRequest = -32600
      CodeMethodNotFound = -32601
      CodeInvalidParams  = -32602
      CodeInternalError  = -32603
    )

## 连接 Conn

Conn是json-rpc的客户端和服务端之间的连接,
client和server是对称的,所以客户端和服务端都会使用Conn对象.

    type Conn struct {
      stream ObjectStream

      h Handler

      mu       sync.Mutex
      shutdown bool
      closing  bool
      seq      uint64
      pending  map[ID]*call

      sending sync.Mutex

      disconnect chan struct{}

      logger Logger

      onRecv []func(*Request, *Response)
      onSend []func(*Request, *Response)
    }

Conn涉及了很多其他对象,我们先一一分析,最后再看Conn提供的功能.

### ObjectStream

ObjectStreram,表示jsonrpc2.9对象的双向流,
通过这个双向流,可以将jsonrpc2.0的对象写到流,也可以从流中取对象.

    type ObjectStream interface {
      WriteObject(obj interface{}) error
      ReadObject(v interface{}) error

      io.Closer
    }

通过GoImplements查看实现类型,发现bufferedObjectStream和子包中的一个类型也实现了.
我们先看bufferedObjectStream:

    type bufferedObjectStream struct {
      conn io.Closer // all writes should go through w, all reads through r
      w    *bufio.Writer
      r    *bufio.Reader

      codec ObjectCodec

      mu sync.Mutex
    }

这个bufferedObjectStream是一个带缓冲的io.ReadWriteCloser来收发对象(jsonrpc2.0的对象).
在具体分析bufferedObjectStream之前,先看看ObjectCodec:

ObjectCodec指明了在流中,如何对jsonrpc2.0的对象进行编解码.

    type ObjectCodec interface {
      WriteObject(stream io.Writer, obj interface{}) error
      ReadObject(stream *bufio.Reader, v interface{}) error
    }

有两个类型实现了ObjectCodec,说明了存在两种编码方式:
VarintObjectCodec和VSCodeObjectCodec.

VarintObjectCodec被称为头部可变长,头部就是长度,先看下写对象:

    type VarintObjectCodec struct{}
    func (VarintObjectCodec) WriteObject(
      stream io.Writer, obj interface{}) error {
      data, err := json.Marshal(obj)
      if err != nil {
        return err
      }
      var buf [binary.MaxVarintLen64]byte
      b := binary.PutUvarint(buf[:], uint64(len(data)))
      if _, err := stream.Write(buf[:b]); err != nil {
        return err
      }
      if _, err := stream.Write(data); err != nil {
        return err
      }
      return nil
    }

binary.MaxVarintLen64是10,表示int64最大位数是10.
binary.PutUvarint表示将一个uint64的数写到一个切片,返回值是写的字节个数.
所以VarintObjectCodec.WriteObject的流程如下:

- 将数据进行json序列化
- 将binary编码后的长度写到stream
- 将json序列化的数据写到stream

因为json序列化的长度是可变的,所以这种编码方式也被称为可变长编码.

    func (VarintObjectCodec) ReadObject(
      stream *bufio.Reader, v interface{}) error {
      b, err := binary.ReadUvarint(stream)
      if err != nil {
        return err
      }
      return json.NewDecoder(io.LimitReader(stream, int64(b))).Decode(v)
    }

先从stream中读一个binary编码的uint64长度,之后从stream读固定长度的数据,
这个数据就是json序列化的数据,反序列化即可.

剩下一种编码格式是VSCodeObjectCodec,头里包含了长度和类型,
这是微软在lsp中定义的一种编码格式.

    type VSCodeObjectCodec struct{}
    func (VSCodeObjectCodec) WriteObject(
      stream io.Writer, obj interface{}) error {
      data, err := json.Marshal(obj)
      if err != nil {
        return err
      }
      if _, err := fmt.Fprintf(
          stream, "Content-Length: %d\r\n\r\n", len(data)); err != nil {
        return err
      }
      if _, err := stream.Write(data); err != nil {
        return err
      }
      return nil
    }

可以看出,Content-Type是固定的(json序列化的数据),所以在实现时,只指明了长度,
这个长度和内容之前有一个空行,而且换行是'\r\n'.

    func (VSCodeObjectCodec) ReadObject(
      stream *bufio.Reader, v interface{}) error {
      var contentLength uint64
      for {
        line, err := stream.ReadString('\r')
        if err != nil {
          return err
        }
        b, err := stream.ReadByte()
        if err != nil {
          return err
        }
        if b != '\n' {
          return fmt.Errorf(`jsonrpc2: line endings must be \r\n`)
        }
        if line == "\r" {
          break
        }
        if strings.HasPrefix(line, "Content-Length: ") {
          line = strings.TrimPrefix(line, "Content-Length: ")
          line = strings.TrimSpace(line)
          var err error
          contentLength, err = strconv.ParseUint(line, 10, 32)
          if err != nil {
            return err
          }
        }
      }
      if contentLength == 0 {
        return fmt.Errorf("jsonrpc2: no Content-Length header found")
      }
      return json.NewDecoder(io.LimitReader(stream, int64(contentLength))).Decode(v)
    }

bufio.Reader.ReadString(),直接读到指定字符,含指定字符.
strings.HasPrefix(),判断某个字符串的前缀是否是xxx.
strings.TrimPrefix(),去掉前缀,如果没有指定前缀,返回原字符串.
strings.TrimSpace(),去首尾空格.

使用一个for循环,很巧妙地将两个'\r\n'都处理了,for循环退出时,正好内容的长度也算出来了.
最后调用json库来做反序列化.

这里过完了两种json编码方式,我们还是回来看bufferedObjectStream.

先看bufferedObjectStream对ObjectStream的实现:

    func (t *bufferedObjectStream) WriteObject(obj interface{}) error {
      t.mu.Lock()
      defer t.mu.Unlock()
      if err := t.codec.WriteObject(t.w, obj); err != nil {
        return err
      }
      return t.w.Flush()
    }
    // 最后还是通过具体的编码方式对象去实现写对象

    func (t *bufferedObjectStream) ReadObject(v interface{}) error {
      return t.codec.ReadObject(t.r, v)
    }

    func (t *bufferedObjectStream) Close() error {
      return t.conn.Close()
    }

再具体分析一下:bufferedObjectStream是不导出的,通过构造函数NewBufferedStream来构造.
再者,具体向stream中读写对象都是通过具体的编码对象来实现的,
所以,bufferedObjectStream实际上提供的是stream的表示,也就是NewBufferedStream指定的,

    func NewBufferedStream(
      conn io.ReadWriteCloser, codec ObjectCodec) ObjectStream {
      return &bufferedObjectStream{
        conn:  conn,
        w:     bufio.NewWriter(conn),
        r:     bufio.NewReader(conn),
        codec: codec,
      }
    }

从这个构造函数可以看出,读写的stream对象就是io.ReadWriteCloser.

至此,跟ObjectStream相关的东西就分析完了(子包中的除外).
我们再回到Conn对象.

### Handler

Conn结构体中的第二个字段.

    type Handler interface {
      Handle(context.Context, *Conn, *Request)
    }

Handler是一个接口,用来处理jsonrpc的请求和通知,
Handle()的处理是一个个请求处理,如果对顺序无要求,就可以使用异步版本AsyncHandler.
我们先看同步版本HandlerWithErrorConfigurer,再看异步版本AsyncHandler.

    type HandlerWithErrorConfigurer struct {
      handleFunc func(
        context.Context, *Conn, *Request) (result interface{}, err error)
      suppressErrClosed bool
    }

这个结构比较简单,包含一个函数和一个标志位.
构造函数是HandlerWithError:

    func HandlerWithError(handleFunc
      func(context.Context, *Conn, *Request) (result interface{}, err error
        )) *HandlerWithErrorConfigurer {
      return &HandlerWithErrorConfigurer{handleFunc: handleFunc}
    }

对Handler的实现如下:

    func (h *HandlerWithErrorConfigurer) Handle(
      ctx context.Context, conn *Conn, req *Request) {
      result, err := h.handleFunc(ctx, conn, req)
      if req.Notif {
        if err != nil {
          conn.logger.Printf("jsonrpc2 handler: notification %q handling error: %v\n",
            req.Method, err)
        }
        return
      }

      resp := &Response{ID: req.ID}
      if err == nil {
        err = resp.SetResult(result)
      }
      if err != nil {
        if e, ok := err.(*Error); ok {
          resp.Error = e
        } else {
          resp.Error = &Error{Message: err.Error()}
        }
      }

      if !req.Notif {
        if err := conn.SendResponse(ctx, resp); err != nil {
          if err != ErrClosed || !h.suppressErrClosed {
            conn.logger.Printf("jsonrpc2 handler: sending response %s: %v\n",
              resp.ID, err)
          }
        }
      }
    }

处理流程如下:

- 构造时指定了处理函数,此时调用处理函数
  - 如果Request是通知,有错就记录;没错就结束
- 如果Request是请求,那么处理函数返回的就是result
  - 构造一个Response
  - 调用conn.SendResponse去发送响应

这个HandlerWithErrorConfigurer还支持忽略连接关闭错误.
接下来看下异步Handler:

    func AsyncHandler(h Handler) Handler {
      return asyncHandler{h}
    }

    type asyncHandler struct {
      Handler
    }

    func (h asyncHandler) Handle(ctx context.Context, conn *Conn, req *Request) {
      go h.Handler.Handle(ctx, conn, req)
    }

异步的比较简单,直接内嵌一个Handler接口对象,用go来做异步处理.
注意,构造函数AsyncHandler是暴露的,实现对象asyncHandler结构体是不暴露的.
因为异步Handler内嵌了Hanlder,所以最终还是会使用到HanlderWithErrorConfigurer.

### call

call表示一个jsonrpc调用的整个生命周期.

    type call struct {
      request  *Request
      response *Response
      seq      uint64 // the seq of the request
      done     chan error
    }

`map[ID]call`用于记录所有的调用.

### Logger

日志记录,标准库的log.Logger实现了

    type Logger interface {
      Printf(format string, v ...interface{})
    }

### Conn分析

确保Conn实现了JSONRPC2接口

    var _ JSONRPC2 = (*Conn)(nil)
    func NewConn(ctx context.Context, stream ObjectStream,
      h Handler, opts ...ConnOpt) *Conn {
      c := &Conn{
        stream:     stream,
        h:          h,
        pending:    map[ID]*call{},
        disconnect: make(chan struct{}),
        logger:     log.New(os.Stderr, "", log.LstdFlags),
      }
      for _, opt := range opts {
        if opt == nil {
          continue
        }
        opt(c)
      }
      go c.readMessages(ctx)
      return c
    }

整个构造是蛮有意思的,ObjectStream和Handler都是接口,传入之前均需要先构造.
日志最后丢到了os.Stderr.
构造还做了两件事情:

- 遍历opt,并对构造的Conn进行处理
- 开启读(协程)

ConnOpt是提供对Conn的自定义处理.Conn.readMessages()是读协程,
在深入研究前,先分析一下anyMessage类型:

### anyMessage

anyMessage表示的是一个Request或一个Response:

    type anyMessage struct {
      request  *Request
      response *Response
    }

    func (m anyMessage) MarshalJSON() ([]byte, error) {
      var v interface{}
      switch {
      case m.request != nil && m.response == nil:
        v = m.request
      case m.request == nil && m.response != nil:
        v = m.response
      }
      if v != nil {
        return json.Marshal(v)
      }
      return nil, errors.New(
        "jsonrpc2: message must have exactly \
        one of the request or response fields set")
    }

json序列化就是调用Request或Response的序列化.

    func (m *anyMessage) UnmarshalJSON(data []byte) error {
      type msg struct {
        ID     interface{}              `json:"id"`
        Method *string                  `json:"method"`
        Result anyValueWithExplicitNull `json:"result"`
        Error  interface{}              `json:"error"`
      }

      var isRequest, isResponse bool
      checkType := func(m *msg) error {
        mIsRequest := m.Method != nil
        mIsResponse := m.Result.null || m.Result.value != nil || m.Error != nil
        if (!mIsRequest && !mIsResponse) || (mIsRequest && mIsResponse) {
          return errors.New(
            "jsonrpc2: unable to determine message type (request or response)")
        }
        if (mIsRequest && isResponse) || (mIsResponse && isRequest) {
          return errors.New(
            "jsonrpc2: batch message type mismatch (must be all requests or all responses)")
        }
        isRequest = mIsRequest
        isResponse = mIsResponse
        return nil
      }

      if isArray := len(data) > 0 && data[0] == '['; isArray {
        var msgs []msg
        if err := json.Unmarshal(data, &msgs); err != nil {
          return err
        }
        if len(msgs) == 0 {
          return errors.New("jsonrpc2: invalid empty batch")
        }
        for i := range msgs {
          if err := checkType(&msg{
            ID:     msgs[i].ID,
            Method: msgs[i].Method,
            Result: msgs[i].Result,
            Error:  msgs[i].Error,
          }); err != nil {
            return err
          }
        }
      } else {
        var m msg
        if err := json.Unmarshal(data, &m); err != nil {
          return err
        }
        if err := checkType(&m); err != nil {
          return err
        }
      }

      var v interface{}
      switch {
      case isRequest && !isResponse:
        v = &m.request
      case !isRequest && isResponse:
        v = &m.response
      }
      if err := json.Unmarshal(data, v); err != nil {
        return err
      }
      if !isRequest && isResponse && m.response.Error == nil
          && m.response.Result == nil {
        m.response.Result = &jsonNull
      }
      return nil
    }

这块的代码可以分成3块:

- 定义一个检测函数,这个函数可以检测反序列化之后,是Request还是Response
- json反序列化,然后用检测函数来判断,支持Request数组或Response数组
- json反序列化到指定对象

### Conn的读协程

读协程是在Conn构造的时候启动的

    // 这个读协程分了两大步:
    // 循环读；退出循环之后的资源释放
    func (c *Conn) readMessages(ctx context.Context) {
      var err error
      for err == nil {

        // 从stream中读数据
        // 当读失败时,退出for循环,这也是唯一退出循环的方式
        var m anyMessage
        err = c.stream.ReadObject(&m)
        if err != nil {
          break
        }

        switch {

        // 如果是Request,先调用onRecv做前处理,在调用Handler来处理请求
        case m.request != nil:
          for _, onRecv := range c.onRecv {
            onRecv(m.request, nil)
          }
          c.h.Handle(ctx, c, m.request)

        case m.response != nil:
          resp := m.response
          if resp != nil {
            id := resp.ID

            // 如果是Response,先从待处理列表pending中删除
            // 因为收到了响应,意味着一次请求已经闭环
            c.mu.Lock()
            call := c.pending[id]
            delete(c.pending, id)
            c.mu.Unlock()

            if call != nil {
              call.response = resp
            }

            // 对Response的一些后处理
            if len(c.onRecv) > 0 {
              var req *Request
              if call != nil {
                req = call.request
              }
              for _, onRecv := range c.onRecv {
                onRecv(req, resp)
              }
            }

            // 最后的错误处理分3类
            // 错误处理之后都会将此次请求-响应的生命周期标记为完结
            switch {
            case call == nil:
              c.logger.Printf(
                "jsonrpc2: ignoring response #%s with no corresponding request\n",
                id)

            case resp.Error != nil:
              call.done <- resp.Error
              close(call.done)

            default:
              call.done <- nil
              close(call.done)
            }
          }
        }
      }

      // stream读失败后,退出循环,释放资源
      c.sending.Lock()
      c.mu.Lock()
      c.shutdown = true
      closing := c.closing
      if err == io.EOF {
        if closing {
          err = ErrClosed
        } else {
          err = io.ErrUnexpectedEOF
        }
      }
      for _, call := range c.pending {
        call.done <- err
        close(call.done)
      }
      c.mu.Unlock()
      c.sending.Unlock()
      if err != io.ErrUnexpectedEOF && !closing {
        c.logger.Printf("jsonrpc2: protocol error: %v\n", err)
      }
      close(c.disconnect)
    }

### Conn对JSONRPC2接口的实现

JSONRPC2接口,Call方法是标准的请求,Notify是通知请求,Close是关闭相关连接.

    type JSONRPC2 interface {
      Call(ctx context.Context, method string, params,
        result interface{}, opt ...CallOption) error
      Notify(ctx context.Context, method string,
        params interface{}, opt ...CallOption) error
      Close() error
    }

对Call的实现:

    func (c *Conn) Call(ctx context.Context, method string, params,
      result interface{}, opts ...CallOption) error {

      //  封装一个请求
      req := &Request{Method: method}
      if err := req.SetParams(params); err != nil {
        return err
      }

      // 对请求的前处理
      for _, opt := range opts {
        if opt == nil {
          continue
        }
        if err := opt.apply(req); err != nil {
          return err
        }
      }

      // 发送请求
      call, err := c.send(ctx, &anyMessage{request: req}, true)
      if err != nil {
        return err
      }

      // 等待返回
      select {

      // 成功返回(从stream上读取到响应)
      case err, ok := <-call.done:
        if !ok {
          err = ErrClosed
        }
        if err != nil {
          return err
        }
        if result != nil {
          if call.response.Result == nil {
            call.response.Result = &jsonNull
          }

          // 最后将响应中的result返回
          if err := json.Unmarshal(*call.response.Result, result); err != nil {
            return err
          }
        }
        return nil

      // 超时或被取消
      case <-ctx.Done():
        return ctx.Err()
      }
    }

对Notify的实现,通知请求和标准请求有些不一样,通知请求没有响应,
发送完毕就返回了:

    func (c *Conn) Notify(ctx context.Context,
      method string, params interface{}, opts ...CallOption) error {
      req := &Request{Method: method, Notif: true}
      if err := req.SetParams(params); err != nil {
        return err
      }
      for _, opt := range opts {
        if opt == nil {
          continue
        }
        if err := opt.apply(req); err != nil {
          return err
        }
      }
      _, err := c.send(ctx, &anyMessage{request: req}, false)
      return err
    }

在实现上Notify和Call类似,只不过不用等待响应.
另外通知请求是没有id的,所以Call的前处理中,必定会对Request添加ID.

对Close的实现:

    func (c *Conn) Close() error {
      c.mu.Lock()
      if c.shutdown || c.closing {
        c.mu.Unlock()
        return ErrClosed
      }
      c.closing = true
      c.mu.Unlock()
      return c.stream.Close()
    }

下面是Conn的其他方法:

    // send, 请求和响应都是通过此函数去发送的
    func (c *Conn) send(_ context.Context, m *anyMessage,
      wait bool) (cc *call, err error) {
      c.sending.Lock()
      defer c.sending.Unlock()

      var id ID

      c.mu.Lock()
      if c.shutdown || c.closing {
        c.mu.Unlock()
        return nil, ErrClosed
      }

      // 如果是标准请求,需要维护一个pending列表
      // 里面每一个元素,表示一次请求的完整生命周期
      if m.request != nil && wait {
        cc = &call{request: m.request, seq: c.seq, done: make(chan error, 1)}
        if !m.request.ID.IsString && m.request.ID.Num == 0 {
          m.request.ID.Num = c.seq
        }
        id = m.request.ID
        c.pending[id] = cc
        c.seq++
      }
      c.mu.Unlock()

      // 发送之前的统一前处理
      if len(c.onSend) > 0 {
        var (
          req  *Request
          resp *Response
        )
        switch {
        case m.request != nil:
          req = m.request
        case m.response != nil:
          resp = m.response
        }
        for _, onSend := range c.onSend {
          onSend(req, resp)
        }
      }

      // 一旦出错,不用等待,直接从pending列表中删除
      defer func() {
        if err != nil {
          if cc != nil {
            c.mu.Lock()
            delete(c.pending, id)
            c.mu.Unlock()
          }
        }
      }()

      // 调用ObjectStream将jsonrpc对象写入到流中
      if err := c.stream.WriteObject(m); err != nil {
        return nil, err
      }
      return cc, nil
    }

Conn.Reply 返回一个响应(成功); Conn.ReplyWithError 返回一个失败的响应
响应都会有一个id和请求的id对应.

    func (c *Conn) Reply(ctx context.Context, id ID, result interface{}) error {
      resp := &Response{ID: id}
      if err := resp.SetResult(result); err != nil {
        return err
      }
      _, err := c.send(ctx, &anyMessage{response: resp}, false)
      return err
    }

    func (c *Conn) ReplyWithError(
      ctx context.Context, id ID, respErr *Error) error {
      _, err := c.send(ctx, &anyMessage{
          response: &Response{ID: id, Error: respErr}}, false)
      return err
    }

    func (c *Conn) SendResponse(ctx context.Context, resp *Response) error {
      _, err := c.send(ctx, &anyMessage{response: resp}, false)
      return err
    }

最后还有个获取"断开连接的channel":

    func (c *Conn) DisconnectNotify() <-chan struct{} {
      return c.disconnect
    }

## 重新分析

到此jsonrpc2的包源码已经过完,但是都是孤岛,没有形成整体认识.
请先跳到[子包websocket](#最后一片)

到目前为止,提供的扩展如下:

- 接收发送的前处理OnSend/OnRecv
- Handler, 对请求如何处理,这块属于业务逻辑
- ObjectStream,这个通过子包,确定了使用websocket

分析到此处,才发现很多结构都是为了测试而出现的,实际上整个jsonrpc2提供的功能是比较简单的.
这个包,除了测试部分,是非常简洁的.

## 最后一片

bufferedObjectStream提供了对ObjectStream的实现,但是基于bufio的,
子包sourcegraph/jsonrpc2/websocket才是基于websocket的jsonrpc2的流.

    type ObjectStream struct {
      conn *ws.Conn
    }

    func NewObjectStream(conn *ws.Conn) ObjectStream {
      return ObjectStream{conn: conn}
    }

    func (t ObjectStream) WriteObject(obj interface{}) error {
      return t.conn.WriteJSON(obj)
    }

    func (t ObjectStream) ReadObject(v interface{}) error {
      err := t.conn.ReadJSON(v)
      if e, ok := err.(*ws.CloseError); ok {
        if e.Code == ws.CloseAbnormalClosure &&
            e.Text == io.ErrUnexpectedEOF.Error() {
          err = io.ErrUnexpectedEOF
        }
      }
      return err
    }

    func (t ObjectStream) Close() error {
      return t.conn.Close()
    }

这里的ws是指 gorilla/websocket.

有了这个子包之后,所有的收发都是基于websocket的.

## ion-sfu中的使用

只使用到了构造Conn对象,以及监听断开连接的信道.

    jc := jsonrpc2.NewConn(r.Context(), websocketjsonrpc2.NewObjectStream(c), p)
    <-jc.DisconnectNotify()

所以sourcegraph/jsonrpc2的扩展功能很多,但ion项目中只用到了ObjectStream和Handler,
而ObjectStream用子包扩展到了websocket,还差Handler没理清楚:

jsonrpc2.NewConn中第三个参数就是Handler,我们先分析何时会调用,最后分析Handler里面具体是什么.

上面分析Conn时,说了:在构造Conn时,会创建一个读协程,
在这个读协程里,有个for循环一直在从stream中读(从websocket中读),
其中读到Request后,会调用Handler来处理:

    c.h.Handle(ctx, c, m.request)

此时,才会调用Handler接口的Handle(). Handler调用的时机找到了,来看看具体的处理逻辑:

    s := sfu.NewSFU(conf)
    p := server.NewJSONSignal(sfu.NewPeer(s))
