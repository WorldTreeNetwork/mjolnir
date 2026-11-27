//! Isolated mechanism probe, not production lifecycle code. No RTC/network credentials.
#[cfg(test)]
mod tests {
    use axum::{body::Body, response::Response, routing::post, Router};
    use bytes::Bytes;
    use http_body::Frame;
    use std::{
        convert::Infallible,
        io,
        pin::Pin,
        sync::{Arc, Mutex},
        task::{Context, Poll},
    };
    use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
    use tower::ServiceExt;

    #[derive(Default, Debug)]
    struct State {
        next: usize,
        pending: Vec<(usize, bool)>,
        committed: Vec<usize>,
        cancelled: Vec<usize>,
        events: Vec<String>,
        bytes: Vec<u8>,
    }
    type Shared = Arc<Mutex<State>>;
    fn cancel(s: &Shared, only: Option<usize>) {
        let mut s = s.lock().unwrap();
        let pending = std::mem::take(&mut s.pending);
        for (id, eof) in pending {
            if only.is_none() || only == Some(id) {
                s.cancelled.push(id);
            } else {
                s.pending.push((id, eof));
            }
        }
    }
    struct MarkedBody {
        data: Option<Bytes>,
        id: usize,
        s: Shared,
        eof: bool,
        yield_pending: bool,
    }
    impl http_body::Body for MarkedBody {
        type Data = Bytes;
        type Error = Infallible;
        fn poll_frame(
            self: Pin<&mut Self>,
            cx: &mut Context<'_>,
        ) -> Poll<Option<Result<Frame<Bytes>, Infallible>>> {
            let me = self.get_mut();
            if me.yield_pending {
                me.yield_pending = false;
                cx.waker().wake_by_ref();
                return Poll::Pending;
            }
            if let Some(mut data) = me.data.take() {
                let chunk = data.split_to(data.len().min(4096));
                if !data.is_empty() {
                    me.data = Some(data);
                    me.yield_pending = true;
                }
                return Poll::Ready(Some(Ok(Frame::data(chunk))));
            }
            me.eof = true;
            let mut s = me.s.lock().unwrap();
            if let Some(p) = s.pending.iter_mut().find(|p| p.0 == me.id) {
                p.1 = true;
            }
            s.events.push(format!("eof {}", me.id));
            Poll::Ready(None)
        }
        // Deliberately no exact size hint or early is_end_stream: Hyper must poll EOF.
    }
    impl Drop for MarkedBody {
        fn drop(&mut self) {
            if !self.eof {
                cancel(&self.s, Some(self.id));
            }
        }
    }
    #[derive(Clone, Copy)]
    enum Mode {
        Ok,
        WriteFail(usize),
        PartialFail(usize),
        FlushFail(usize),
        StallFlush(usize),
        Zero(usize),
    }
    struct Wire {
        request: Option<Vec<u8>>,
        s: Shared,
        mode: Mode,
        partial: bool,
        max_write: usize,
    }
    impl AsyncRead for Wire {
        fn poll_read(
            self: Pin<&mut Self>,
            _: &mut Context<'_>,
            b: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            let me = self.get_mut();
            if let Some(req) = me.request.take() {
                b.put_slice(&req);
                Poll::Ready(Ok(()))
            } else {
                Poll::Pending
            }
        }
    }
    impl AsyncWrite for Wire {
        fn poll_write(
            self: Pin<&mut Self>,
            _: &mut Context<'_>,
            b: &[u8],
        ) -> Poll<io::Result<usize>> {
            let me = self.get_mut();
            let mut s = me.s.lock().unwrap();
            let id = s.pending.first().map(|p| p.0).unwrap_or(0);
            s.events.push(format!("write {id}"));
            match me.mode {
                Mode::WriteFail(i) if i == id => {
                    return Poll::Ready(Err(io::ErrorKind::BrokenPipe.into()))
                }
                Mode::PartialFail(i) if i == id && me.partial => {
                    return Poll::Ready(Err(io::ErrorKind::BrokenPipe.into()))
                }
                Mode::Zero(i) if i == id => return Poll::Ready(Ok(0)),
                _ => {}
            }
            let n = b.len().min(me.max_write);
            me.partial = true;
            s.bytes.extend_from_slice(&b[..n]);
            Poll::Ready(Ok(n))
        }
        fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
            let me = self.get_mut();
            let s = me.s.lock().unwrap();
            let id = s.pending.first().map(|p| p.0).unwrap_or(0);
            match me.mode {
                Mode::FlushFail(i) if i == id => {
                    return Poll::Ready(Err(io::ErrorKind::BrokenPipe.into()))
                }
                Mode::StallFlush(i) if i == id => return Poll::Pending,
                _ => {}
            }
            Poll::Ready(Ok(()))
        }
        fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }
    }
    // Wrapper sees Hyper's *underlying* flush, after Hyper drains its own buffer.
    struct ObservedIo {
        inner: Wire,
        s: Shared,
    }
    impl AsyncRead for ObservedIo {
        fn poll_read(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            b: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            Pin::new(&mut self.inner).poll_read(cx, b)
        }
    }
    impl AsyncWrite for ObservedIo {
        fn poll_write(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            b: &[u8],
        ) -> Poll<io::Result<usize>> {
            Pin::new(&mut self.inner).poll_write(cx, b)
        }
        fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            let result = Pin::new(&mut self.inner).poll_flush(cx);
            if matches!(result, Poll::Ready(Ok(()))) {
                let mut s = self.s.lock().unwrap();
                s.events.push("flush-ok".into());
                let pending = std::mem::take(&mut s.pending);
                for (id, eof) in pending {
                    if eof {
                        s.committed.push(id);
                        s.events.push(format!("commit {id}"));
                    } else {
                        s.pending.push((id, eof));
                    }
                }
            }
            result
        }
        fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Pin::new(&mut self.inner).poll_shutdown(cx)
        }
    }
    impl Drop for ObservedIo {
        fn drop(&mut self) {
            cancel(&self.s, None);
        }
    }

    async fn drive(mode: Mode, count: usize, body_size: usize, close: bool) -> Shared {
        let s = Shared::default();
        // Existing RTC session is intentionally outside the connection's pending set.
        s.lock().unwrap().committed.push(99);
        let app = Router::new().route(
            "/",
            post({
                let s = s.clone();
                move || {
                    let s = s.clone();
                    async move {
                        let id = {
                            let mut state = s.lock().unwrap();
                            state.next += 1;
                            let id = state.next;
                            state.pending.push((id, false));
                            id
                        };
                        Response::builder()
                            .status(201)
                            .body(Body::new(MarkedBody {
                                data: Some(Bytes::from(vec![b'x'; body_size])),
                                id,
                                s,
                                eof: false,
                                yield_pending: false,
                            }))
                            .unwrap()
                    }
                }
            }),
        );
        let mut request = String::new();
        for i in 0..count {
            request.push_str(&format!(
                "POST / HTTP/1.1\r\nHost: edge\r\nContent-Length: 0\r\n{}\r\n",
                if close && i + 1 == count {
                    "Connection: close\r\n"
                } else {
                    ""
                }
            ));
        }
        let io = ObservedIo {
            inner: Wire {
                request: Some(request.into_bytes()),
                s: s.clone(),
                mode,
                partial: false,
                max_write: 17,
            },
            s: s.clone(),
        };
        let service = hyper::service::service_fn(move |req| app.clone().oneshot(req));
        let mut builder = hyper::server::conn::http1::Builder::new();
        builder.pipeline_flush(false); // part of the supported mechanism, not default reliance
        let conn = builder.serve_connection(hyper_util::rt::TokioIo::new(io), service);
        // A timeout drops the connection future, including its pending cancellation owner.
        let result = tokio::time::timeout(std::time::Duration::from_millis(200), conn).await;
        let state = s.lock().unwrap();
        println!(
            "result={result:?} committed={:?} cancelled={:?} bytes={} events={:?}",
            state.committed,
            state.cancelled,
            state.bytes.len(),
            if body_size < 1000 {
                &state.events[..]
            } else {
                &state.events[..0]
            }
        );
        assert!(state.pending.is_empty());
        drop(state);
        s
    }
    #[tokio::test]
    async fn success_close_partial_writes() {
        let s = drive(Mode::Ok, 1, 200, true).await;
        assert_eq!(s.lock().unwrap().committed, [99, 1]);
    }
    #[tokio::test]
    async fn success_keepalive_then_connection_cancel() {
        let s = drive(Mode::Ok, 1, 200, false).await;
        assert_eq!(s.lock().unwrap().committed, [99, 1]);
    }
    #[tokio::test]
    async fn write_failure_after_eof() {
        let s = drive(Mode::WriteFail(1), 1, 200, true).await;
        let s = s.lock().unwrap();
        assert_eq!(s.committed, [99]);
        assert_eq!(s.cancelled, [1]);
        assert!(s.events.iter().any(|e| e == "eof 1"));
    }
    #[tokio::test]
    async fn partial_write_failure() {
        let s = drive(Mode::PartialFail(1), 1, 200, true).await;
        let s = s.lock().unwrap();
        assert_eq!(s.committed, [99]);
        assert_eq!(s.cancelled, [1]);
        assert_eq!(s.bytes.len(), 17);
    }
    #[tokio::test]
    async fn flush_failure() {
        let s = drive(Mode::FlushFail(1), 1, 200, true).await;
        assert_eq!(s.lock().unwrap().cancelled, [1]);
    }
    #[tokio::test]
    async fn cancellation_after_eof_before_flush() {
        let s = drive(Mode::StallFlush(1), 1, 200, true).await;
        let s = s.lock().unwrap();
        assert_eq!(s.committed, [99]);
        assert_eq!(s.cancelled, [1]);
    }
    #[tokio::test]
    async fn pipelined_success_then_failure_preserves_first() {
        let s = drive(Mode::WriteFail(2), 2, 200, true).await;
        let s = s.lock().unwrap();
        assert_eq!(s.committed, [99, 1]);
        assert_eq!(s.cancelled, [2]);
    }
    #[tokio::test]
    async fn pipelined_success() {
        let s = drive(Mode::Ok, 3, 200, true).await;
        assert_eq!(s.lock().unwrap().committed, [99, 1, 2, 3]);
    }
    #[tokio::test]
    async fn large_body_early_flush_does_not_commit() {
        let s = drive(Mode::PartialFail(1), 1, 400_000, true).await;
        assert_eq!(s.lock().unwrap().committed, [99]);
    }
    #[tokio::test]
    async fn large_body_success_flushes_before_eof() {
        let s = drive(Mode::Ok, 1, 400_000, true).await;
        let s = s.lock().unwrap();
        assert_eq!(s.committed, [99, 1]);
        let first_flush = s.events.iter().position(|e| e == "flush-ok").unwrap();
        let eof = s.events.iter().position(|e| e == "eof 1").unwrap();
        let commit = s.events.iter().position(|e| e == "commit 1").unwrap();
        assert!(first_flush < eof && eof < commit);
    }
    #[tokio::test]
    async fn unconsumed_body_drop() {
        let s = Shared::default();
        s.lock().unwrap().pending.push((1, false));
        drop(MarkedBody {
            data: Some(Bytes::from_static(b"SDP")),
            id: 1,
            s: s.clone(),
            eof: false,
            yield_pending: false,
        });
        assert_eq!(s.lock().unwrap().cancelled, [1]);
    }
    #[tokio::test]
    async fn zero_write() {
        let s = drive(Mode::Zero(1), 1, 200, true).await;
        assert_eq!(s.lock().unwrap().cancelled, [1]);
    }
}
