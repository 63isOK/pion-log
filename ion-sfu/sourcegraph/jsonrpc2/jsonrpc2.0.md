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

## 连接

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
