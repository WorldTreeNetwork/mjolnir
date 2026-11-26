//! Spike edge: WHIP/WHEP beside the Mjolnir relay. Not product code.
//!
//!   edge <listen> <media-udp> <relay-url> <verify-keys.json> [--no-expiry-timer]
//!
//! POST /whip/<room>/<broadcast...>   publish  (broadcast relative to the token's root)
//! POST /whep/<room>/<broadcast...>   play
//! GET  /roster/<room>                broadcasts announced in the room right now (JSON)
//! DELETE /session/<id>               end a WHIP/WHEP session (RFC 9725 resource)
//!
//! The bearer is a room token. The edge verifies it with the relay's own verify set
//! (`mjolnir_relay::assess`), takes the room root from the verified claims, refuses a
//! broadcast outside the token's publish (WHIP) or subscribe (WHEP) grant, and opens its
//! relay session with the same token, so it holds no authority of its own.
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use moq_auth::{Grant, KeySet};

#[derive(Clone)]
struct Edge {
    media: moq_webrtc::Server,
    relay: url::Url,
    keys: Arc<Mutex<KeySet>>,
    expiry_timer: bool,
    ingest_mbps: Option<f64>,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Kind {
    Whip,
    Whep,
}

type Reply = (StatusCode, HeaderMap, String);

fn refuse(status: StatusCode, why: impl Into<String>) -> Reply {
    let why = why.into();
    tracing::warn!(%status, %why, "refused");
    (status, HeaderMap::new(), why)
}

/// Verify the bearer and return the grant plus the room the verified root names.
fn admit(edge: &Edge, headers: &HeaderMap, room: &str) -> Result<(String, Grant), Reply> {
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or_else(|| refuse(StatusCode::UNAUTHORIZED, "no token"))?
        .to_string();
    let keys = edge.keys.lock().unwrap().clone();
    // Same profile as the relay's deciders: algorithm, signature, exp/iat/ttl, root shape.
    let grant = mjolnir_relay::assess(Some(&token), "", &keys, mjolnir_relay::DEFAULT_MAX_TTL)
        .map_err(|err| refuse(StatusCode::UNAUTHORIZED, err.to_string()))?;
    let root = grant.root.clone().unwrap_or_default();
    let parts: Vec<&str> = root.split('/').collect();
    // A room token's root is exactly t/<owner>/<room>; the URL's room is only checked against it.
    if parts.len() != 3 || parts[2] != room {
        return Err(refuse(StatusCode::FORBIDDEN, "token is not for this room"));
    }
    Ok((token, grant))
}

fn client(edge: &Edge) -> moq_tokio::Client {
    let mut config = moq_tokio::connect::Config::default();
    config.tls.insecure = Some(std::env::var("EDGE_RELAY_VERIFY").as_deref() != Ok("1"));
    config.bind = Some("127.0.0.1:0".parse().unwrap());
    let _ = edge;
    config.init(Default::default()).expect("client").with_reconnect(false)
}

fn relay_url(edge: &Edge, token: &str) -> url::Url {
    let mut url = edge.relay.clone();
    url.query_pairs_mut().append_pair("jwt", token);
    url
}

async fn offer(edge: Edge, kind: Kind, room: String, broadcast: String, headers: HeaderMap, body: Bytes) -> Reply {
    let started = Instant::now();
    let (token, grant) = match admit(&edge, &headers, &room) {
        Ok(ok) => ok,
        Err(reply) => return reply,
    };
    let broadcast = broadcast.trim_matches('/').to_string();
    if broadcast.is_empty() || broadcast.split('/').any(|s| s.is_empty() || s == "." || s == "..") {
        return refuse(StatusCode::BAD_REQUEST, "bad broadcast path");
    }
    let allowed = match kind {
        Kind::Whip => grant.publish.path.matches(&broadcast),
        Kind::Whep => grant.subscribe.path.matches(&broadcast),
    };
    if !allowed {
        return refuse(StatusCode::FORBIDDEN, format!("{kind:?} of {broadcast} is outside the token grant"));
    }
    let ct = headers.get(header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).unwrap_or("");
    if !ct.eq_ignore_ascii_case("application/sdp") {
        return refuse(StatusCode::UNSUPPORTED_MEDIA_TYPE, "expected application/sdp");
    }
    let Ok(sdp) = std::str::from_utf8(&body) else {
        return refuse(StatusCode::BAD_REQUEST, "offer is not utf-8");
    };
    let Ok(path) = moq_net::Path::new(broadcast.as_str()) else {
        return refuse(StatusCode::BAD_REQUEST, "bad broadcast path");
    };
    let origin = moq_tokio::origin::spawn();
    let connect = match kind {
        Kind::Whip => client(&edge).with_publisher(origin.consume()),
        Kind::Whep => client(&edge).with_subscriber(origin.clone()),
    };
    let conn = match tokio::time::timeout(Duration::from_secs(5), connect.connect(relay_url(&edge, &token)).established()).await {
        Ok(Ok(conn)) => conn,
        Ok(Err(err)) => return refuse(StatusCode::FORBIDDEN, format!("relay refused the session: {err}")),
        Err(_) => return refuse(StatusCode::BAD_GATEWAY, "relay timeout"),
    };
    let accepted = match kind {
        Kind::Whip => {
            let mut request = moq_webrtc::whip::Request::new(&origin, path.clone(), sdp);
            // A cap both bounds the publisher and makes the session send REMB; uncapped, it sends none.
            if let Some(mbps) = edge.ingest_mbps {
                let cap = moq_net::bandwidth::Cap::new(moq_net::bandwidth::Rate::from_bps((mbps * 1e6) as u64));
                request.ingest.rate = Some(moq_net::bandwidth::Limit::new(cap));
            }
            moq_webrtc::whip::accept(&edge.media, request).await
        }
        Kind::Whep => {
            let consumer = origin.consume();
            moq_webrtc::whep::accept(&edge.media, moq_webrtc::whep::Request::new(&consumer, path.clone(), sdp)).await
        }
    };
    let response = match accepted {
        Ok(r) => r,
        Err(err) => {
            let status = match &err {
                moq_webrtc::Error::InvalidSdp(_) | moq_webrtc::Error::InvalidPath(_) => StatusCode::BAD_REQUEST,
                moq_webrtc::Error::UnsupportedCodec(_) | moq_webrtc::Error::NoRenditions => StatusCode::UNSUPPORTED_MEDIA_TYPE,
                moq_webrtc::Error::Moq(moq_net::Error::NotFound | moq_net::Error::Unroutable) => StatusCode::NOT_FOUND,
                moq_webrtc::Error::Moq(moq_net::Error::Unauthorized) => StatusCode::FORBIDDEN,
                _ => StatusCode::UNPROCESSABLE_ENTITY,
            };
            return refuse(status, format!("{kind:?} {broadcast}: {err}"));
        }
    };
    let id = response.resource_id.clone();
    let answer = response.answer.clone();
    let expires = grant.expires.map(SystemTime::from);
    let left = expires.and_then(|e| e.duration_since(SystemTime::now()).ok()).unwrap_or(Duration::ZERO);
    let timer = edge.expiry_timer;
    let task_id = id.clone();
    tracing::info!(?kind, %room, %broadcast, %id, ttl_ms = left.as_millis() as u64, setup_ms = started.elapsed().as_millis() as u64, "session accepted");
    tokio::spawn(async move {
        let begun = Instant::now();
        let ended = tokio::select! {
            res = response.run() => format!("webrtc ended: {res:?}"),
            res = conn.closed() => format!("relay session closed: {res:?}"),
            _ = tokio::time::sleep(left), if timer => "token expired (edge timer)".to_string(),
        };
        // Dropping the response and connection here tears down both legs.
        tracing::info!(?kind, %broadcast, id = %task_id, after_ms = begun.elapsed().as_millis() as u64, %ended, "session ended");
    });
    let mut out = HeaderMap::new();
    out.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/sdp"));
    out.insert(header::LOCATION, HeaderValue::from_str(&format!("/session/{id}")).unwrap());
    (StatusCode::CREATED, out, answer)
}

async fn whip(State(edge): State<Edge>, Path((room, b)): Path<(String, String)>, h: HeaderMap, body: Bytes) -> Reply {
    offer(edge, Kind::Whip, room, b, h, body).await
}

async fn whep(State(edge): State<Edge>, Path((room, b)): Path<(String, String)>, h: HeaderMap, body: Bytes) -> Reply {
    offer(edge, Kind::Whep, room, b, h, body).await
}

/// The resource id is an unguessable capability, as in RFC 9725.
async fn end(State(edge): State<Edge>, Path(id): Path<String>) -> StatusCode {
    if edge.media.terminate(&id) { StatusCode::OK } else { StatusCode::NOT_FOUND }
}

/// Who is publishing in the room: one subscriber session, a short announce window.
async fn roster(State(edge): State<Edge>, Path(room): Path<String>, headers: HeaderMap) -> Reply {
    let (token, _grant) = match admit(&edge, &headers, &room) {
        Ok(ok) => ok,
        Err(reply) => return reply,
    };
    let origin = moq_tokio::origin::spawn();
    let mut announced = origin.consume().announced();
    let Ok(Ok(conn)) = tokio::time::timeout(
        Duration::from_secs(5),
        client(&edge).with_subscriber(origin.clone()).connect(relay_url(&edge, &token)).established(),
    )
    .await
    else {
        return refuse(StatusCode::BAD_GATEWAY, "relay session failed");
    };
    let mut live = std::collections::BTreeSet::new();
    let deadline = tokio::time::Instant::now() + Duration::from_millis(700);
    while let Ok(Some(event)) = tokio::time::timeout_at(deadline, announced.next()).await {
        match event {
            moq_net::announce::Event::Present(a) => {
                live.insert(a.prefix.to_string());
            }
            moq_net::announce::Event::Absent(a) | moq_net::announce::Event::Offline(a) => {
                live.remove(&a.prefix.to_string());
            }
            _ => {}
        }
    }
    drop(conn);
    let mut out = HeaderMap::new();
    out.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
    (StatusCode::OK, out, serde_json::json!({ "broadcasts": live }).to_string())
}

/// Browsers send a preflight for the Authorization header; WHIP pages live on other origins.
async fn cors(req: axum::extract::Request, next: axum::middleware::Next) -> Response {
    let mut res = if req.method() == Method::OPTIONS {
        StatusCode::NO_CONTENT.into_response()
    } else {
        next.run(req).await
    };
    let h = res.headers_mut();
    h.insert("access-control-allow-origin", HeaderValue::from_static("*"));
    h.insert("access-control-allow-methods", HeaderValue::from_static("POST, GET, DELETE, OPTIONS"));
    h.insert("access-control-allow-headers", HeaderValue::from_static("authorization, content-type"));
    h.insert("access-control-expose-headers", HeaderValue::from_static("location"));
    res
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .with_ansi(false)
        .init();
    let _ = moq_tokio::crypto::install_default();
    let args: Vec<String> = std::env::args().collect();
    let listen: SocketAddr = args[1].parse()?;
    let media_addr: SocketAddr = args[2].parse()?;
    let relay: url::Url = args[3].parse()?;
    let keys: KeySet = std::fs::read_to_string(&args[4])?.parse().map_err(|e| anyhow::anyhow!("keys: {e}"))?;
    let media = moq_webrtc::Server::bind(media_addr, Default::default()).await?;
    tracing::info!(media = %media.local_addr(), %listen, "edge up");
    let edge = Edge {
        media,
        relay,
        keys: Arc::new(Mutex::new(keys)),
        expiry_timer: !args.iter().any(|a| a == "--no-expiry-timer"),
        ingest_mbps: std::env::var("EDGE_INGEST_MBPS").ok().and_then(|v| v.parse().ok()).filter(|v: &f64| *v > 0.0),
    };
    let app = axum::Router::new()
        .route("/whip/{room}/{*broadcast}", post(whip))
        .route("/whep/{room}/{*broadcast}", post(whep))
        .route("/roster/{room}", get(roster))
        .route("/session/{id}", delete(end))
        .layer(axum::middleware::from_fn(cors))
        .with_state(edge);
    let listener = tokio::net::TcpListener::bind(listen).await?;
    axum::serve(listener, app).with_graceful_shutdown(async { let _ = tokio::signal::ctrl_c().await; }).await?;
    Ok(())
}
