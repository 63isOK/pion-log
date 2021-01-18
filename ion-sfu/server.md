# jsonrpc的sfu服务

对应的是ion-sfu/cmd/signal/json-rpc/server/server.go

    type Join struct {
      Sid   string                    `json:"sid"`
      Offer webrtc.SessionDescription `json:"offer"`
    }

    type Negotiation struct {
      Desc webrtc.SessionDescription `json:"desc"`
    }

    type Trickle struct {
      Target    int                     `json:"target"`
      Candidate webrtc.ICECandidateInit `json:"candidate"`
    }

3个结构体类型,对应着3种信令.

    type JSONSignal struct {
      *sfu.Peer
    }

    func NewJSONSignal(p *sfu.Peer) *JSONSignal {
      return &JSONSignal{p}
    }

JSONSignal类型的定义和构造,JSONSignal内嵌了`*.sfu.Peer`,
JSONSignal还实现了sourcegraph/jsonrpc2.Handler接口:

    func (p *JSONSignal) Handle(
      ctx context.Context, conn *jsonrpc2.Conn, req *jsonrpc2.Request) {
      replyError := func(err error) {
        _ = conn.ReplyWithError(ctx, req.ID, &jsonrpc2.Error{
          Code:    500,
          Message: fmt.Sprintf("%s", err),
        })
      }

      // 从下面的代码可知,上面定义的3个信令结构体,只是用来放jsonrpc的参数的.
      switch req.Method {
      case "join":
        var join Join
        err := json.Unmarshal(*req.Params, &join)
        if err != nil {
          log.Errorf("connect: error parsing offer: %v", err)
          replyError(err)
          break
        }

        // 指定了OnOffer/OnIceCandidate两个回调函数
        p.OnOffer = func(offer *webrtc.SessionDescription) {
          if err := conn.Notify(ctx, "offer", offer); err != nil {
            log.Errorf("error sending offer %s", err)
          }
        }

        p.OnIceCandidate = func(candidate *webrtc.ICECandidateInit, target int) {
          if err := conn.Notify(ctx, "trickle", Trickle{
            Candidate: *candidate,
            Target:    target,
          }); err != nil {
            log.Errorf("error sending ice candidate %s", err)
          }
        }

        // 处理sdp offer,获得sdp answer
        answer, err := p.Join(join.Sid, join.Offer)
        if err != nil {
          replyError(err)
          break
        }

        // 返回成功
        _ = conn.Reply(ctx, req.ID, answer)

      case "offer":
        var negotiation Negotiation
        err := json.Unmarshal(*req.Params, &negotiation)
        if err != nil {
          log.Errorf("connect: error parsing offer: %v", err)
          replyError(err)
          break
        }

        // 收到sdp offer,生成sdp answer
        // 这个和join还是有些许差别的,具体是什么差别,需要查看sfu的源码
        // 这块后面会具体分析到
        answer, err := p.Answer(negotiation.Desc)
        if err != nil {
          replyError(err)
          break
        }
        _ = conn.Reply(ctx, req.ID, answer)

      case "answer":
        var negotiation Negotiation
        err := json.Unmarshal(*req.Params, &negotiation)
        if err != nil {
          log.Errorf("connect: error parsing offer: %v", err)
          replyError(err)
          break
        }

        // 收到answer,说明本端是发起方
        err = p.SetRemoteDescription(negotiation.Desc)
        if err != nil {
          replyError(err)
        }

      case "trickle":
        var trickle Trickle
        err := json.Unmarshal(*req.Params, &trickle)
        if err != nil {
          log.Errorf("connect: error parsing candidate: %v", err)
          replyError(err)
          break
        }

        // ice 处理
        err = p.Trickle(trickle.Candidate, trickle.Target)
        if err != nil {
          replyError(err)
        }
      }
    }

看到这里,ion-sfu中处理jsonrpc2的逻辑部分已经分析完了,
但是感觉还是少了些什么.那么分析一个具体的html吧.

## html的流程分析

通过抓包分析,网页和ion-sfu之间的websocket信令如下:

client(html)到server(ion-sfu):

- join信令,里面包含sid和sdp offer(这个offer仅仅是datachannel的)
- ice

server端返回:

- answer信令,里面的answer对应datachannel的应答
- ice

client继续发送:

- offer信令,此时发送的是正常的sdp offer
- ice

server返回:

- answer信令,jsonrpc参数里包含的是sdp answer
