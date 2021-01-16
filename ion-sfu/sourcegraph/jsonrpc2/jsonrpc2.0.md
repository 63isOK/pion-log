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

todo
