//! HTTP/1 admission listener.
//!
//! Body EOF marks the SDP as serialized. It is not delivery. `DeliveryIo`
//! acknowledges a ticket only after the underlying `poll_flush` returns
//! `Ready(Ok(()))`. That is local transport acceptance of the bytes this
//! process handed to the socket, not TCP peer receipt, proxy forwarding, or
//! browser application of the SDP.
//!
//! HTTP/2 is not spoken here. Flow control can retain one stream's DATA while
//! another stream's flush succeeds, so the EOF-then-next-flush rule would be a
//! false commit. The builder is `hyper::server::conn::http1` only. An `h2`
//! preface fails that connection. The listener is plain HTTP and does not
//! advertise HTTP/2.

use std::convert::Infallible;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};

use axum::Router;
use bytes::Bytes;
use http_body::Frame;
use hyper::body::Incoming;
use hyper::service::service_fn;
use tokio::io::{AsyncRead, AsyncWrite};
use tower::ServiceExt;

use crate::edge::Edge;

const CHUNK: usize = 4096;

#[derive(Clone)]
pub struct DeliveryContext {
    inner: Arc<Mutex<Ctx>>,
}

struct Ctx {
    tickets: Vec<Ticket>,
}

struct Ticket {
    edge: Arc<Edge>,
    id: String,
    generation: u64,
    serialized: bool,
    settled: bool,
}

impl DeliveryContext {
    fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(Ctx { tickets: Vec::new() })),
        }
    }

    pub(crate) fn enroll(&self, edge: Arc<Edge>, id: &str, generation: u64) {
        let mut ctx = self.inner.lock().expect("delivery");
        if ctx.tickets.iter().any(|ticket| ticket.id == id && ticket.generation == generation) {
            return;
        }
        ctx.tickets.push(Ticket {
            edge,
            id: id.to_string(),
            generation,
            serialized: false,
            settled: false,
        });
    }

    fn mark_serialized(&self, id: &str, generation: u64) {
        let mut ctx = self.inner.lock().expect("delivery");
        if let Some(ticket) = ctx
            .tickets
            .iter_mut()
            .find(|ticket| ticket.id == id && ticket.generation == generation && !ticket.settled)
        {
            ticket.serialized = true;
        }
    }

    fn cancel_one(&self, id: &str, generation: u64) {
        let ticket = {
            let mut ctx = self.inner.lock().expect("delivery");
            let Some(pos) = ctx
                .tickets
                .iter()
                .position(|ticket| ticket.id == id && ticket.generation == generation && !ticket.settled)
            else {
                return;
            };
            let mut ticket = ctx.tickets.swap_remove(pos);
            ticket.settled = true;
            ticket
        };
        ticket.edge.cancel_delivery(&ticket.id, ticket.generation);
    }

    fn commit_serialized(&self) {
        let ready: Vec<Ticket> = {
            let mut ctx = self.inner.lock().expect("delivery");
            let mut ready = Vec::new();
            for ticket in &mut ctx.tickets {
                if ticket.serialized && !ticket.settled {
                    ticket.settled = true;
                    ready.push(Ticket {
                        edge: Arc::clone(&ticket.edge),
                        id: ticket.id.clone(),
                        generation: ticket.generation,
                        serialized: true,
                        settled: true,
                    });
                }
            }
            ready
        };
        for ticket in ready {
            if !ticket.edge.ack_delivery(&ticket.id, ticket.generation) {
                ticket.edge.cancel_delivery(&ticket.id, ticket.generation);
            }
        }
    }

    fn cancel_outstanding(&self) {
        let pending: Vec<Ticket> = {
            let mut ctx = self.inner.lock().expect("delivery");
            let mut pending = Vec::new();
            for ticket in &mut ctx.tickets {
                if !ticket.settled {
                    ticket.settled = true;
                    pending.push(Ticket {
                        edge: Arc::clone(&ticket.edge),
                        id: ticket.id.clone(),
                        generation: ticket.generation,
                        serialized: ticket.serialized,
                        settled: true,
                    });
                }
            }
            pending
        };
        for ticket in pending {
            ticket.edge.cancel_delivery(&ticket.id, ticket.generation);
        }
    }
}

impl Drop for DeliveryContext {
    fn drop(&mut self) {
        if Arc::strong_count(&self.inner) == 1 {
            self.cancel_outstanding();
        }
    }
}

pub struct AnswerBody {
    rest: Option<Bytes>,
    edge: Arc<Edge>,
    id: String,
    generation: u64,
    ctx: DeliveryContext,
    serialized: bool,
    yield_pending: bool,
}

impl AnswerBody {
    pub(crate) fn new(answer: String, edge: Arc<Edge>, id: String, generation: u64, ctx: DeliveryContext) -> Self {
        ctx.enroll(Arc::clone(&edge), &id, generation);
        Self {
            rest: Some(Bytes::from(answer)),
            edge,
            id,
            generation,
            ctx,
            serialized: false,
            yield_pending: false,
        }
    }
}

impl Drop for AnswerBody {
    fn drop(&mut self) {
        if !self.serialized {
            self.ctx.cancel_one(&self.id, self.generation);
            // cancel_one already asked the edge. A ticket enrolled and removed
            // there will not be cancelled again on connection drop.
            let _ = &self.edge;
        }
    }
}

impl http_body::Body for AnswerBody {
    type Data = Bytes;
    type Error = Infallible;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        let this = self.get_mut();
        if this.yield_pending {
            this.yield_pending = false;
            cx.waker().wake_by_ref();
            return Poll::Pending;
        }
        if let Some(mut rest) = this.rest.take() {
            let chunk = rest.split_to(rest.len().min(CHUNK));
            if !rest.is_empty() {
                this.rest = Some(rest);
                this.yield_pending = true;
            }
            return Poll::Ready(Some(Ok(Frame::data(chunk))));
        }
        this.serialized = true;
        this.ctx.mark_serialized(&this.id, this.generation);
        Poll::Ready(None)
    }
}

pin_project_lite::pin_project! {
    pub struct DeliveryIo<I> {
        #[pin]
        inner: I,
        ctx: DeliveryContext,
    }
}

impl<I> DeliveryIo<I> {
    fn new(inner: I, ctx: DeliveryContext) -> Self {
        Self { inner, ctx }
    }
}

impl<I> AsyncRead for DeliveryIo<I>
where
    I: AsyncRead,
{
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        self.project().inner.poll_read(cx, buf)
    }
}

impl<I> AsyncWrite for DeliveryIo<I>
where
    I: AsyncWrite,
{
    fn poll_write(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<std::io::Result<usize>> {
        self.project().inner.poll_write(cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        let this = self.project();
        let result = this.inner.poll_flush(cx);
        if matches!(result, Poll::Ready(Ok(()))) {
            this.ctx.commit_serialized();
        }
        result
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        self.project().inner.poll_shutdown(cx)
    }

    fn poll_write_vectored(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bufs: &[std::io::IoSlice<'_>],
    ) -> Poll<std::io::Result<usize>> {
        self.project().inner.poll_write_vectored(cx, bufs)
    }

    fn is_write_vectored(&self) -> bool {
        self.inner.is_write_vectored()
    }
}

/// One accepted connection. HTTP/1 only, with `pipeline_flush(false)` so
/// response A is flushed before response B is written.
pub async fn serve_connection<I>(io: I, router: Router) -> Result<(), hyper::Error>
where
    I: AsyncRead + AsyncWrite + Send + Unpin + 'static,
{
    let ctx = DeliveryContext::new();
    let io = DeliveryIo::new(io, ctx.clone());
    let req_ctx = ctx.clone();
    let svc = service_fn(move |req: hyper::Request<Incoming>| {
        let router = router.clone();
        let ctx = req_ctx.clone();
        async move {
            let mut req = req.map(axum::body::Body::new);
            req.extensions_mut().insert(ctx);
            router.oneshot(req).await.map_err(|_| {
                std::io::Error::other("edge router rejected the request")
            })
        }
    });
    let conn = hyper::server::conn::http1::Builder::new()
        .pipeline_flush(false)
        .serve_connection(hyper_util::rt::TokioIo::new(io), svc);
    let result = conn.await;
    // Connection future ended: Ok, read EOF, write/flush failure, or cancel.
    // Tickets already committed on a successful flush are settled and stay up.
    ctx.cancel_outstanding();
    result
}

pub async fn serve(listener: tokio::net::TcpListener, router: Router) -> std::io::Result<()> {
    loop {
        let (stream, _) = listener.accept().await?;
        let router = router.clone();
        tokio::spawn(async move {
            if let Err(err) = serve_connection(stream, router).await {
                tracing::debug!(%err, "http/1 connection ended");
            }
        });
    }
}
