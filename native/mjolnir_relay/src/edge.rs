//! Local WebRTC-edge admission. The process holds no mint key.
//! Each pooled relay connection is opened with that leg's own token.
//! `/admit` never dials.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, post};
use axum::{Json, Router};
use moq_auth::{Grant, KeySet};
use moq_pattern::Pattern;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::{assess, key_file_trusted, load_verify_keys, Refuse, DEFAULT_MAX_TTL};

const SETUP_BUDGET: Duration = Duration::from_secs(5);
const TOMBSTONE: Duration = Duration::from_secs(30);
const PATH_BOUND: usize = 4096;
const DEPTH_BOUND: usize = 32;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Op {
    Publish,
    Subscribe,
}

#[derive(Debug, PartialEq, Eq)]
pub enum AdmitError {
    NoToken,
    BadRequest,
    BadToken,
    RoomNotOpen,
    UnexpectedRoot,
    Forbidden,
    NotStarted,
    CodecUnavailable,
    SetupFailed,
    NotFound,
}

impl AdmitError {
    fn status(self) -> (StatusCode, &'static str) {
        match self {
            Self::NoToken => (StatusCode::UNAUTHORIZED, "no_token"),
            Self::BadRequest => (StatusCode::BAD_REQUEST, "bad_request"),
            Self::BadToken => (StatusCode::FORBIDDEN, "bad_token"),
            Self::RoomNotOpen => (StatusCode::FORBIDDEN, "room_not_open"),
            Self::UnexpectedRoot => (StatusCode::FORBIDDEN, "unexpected_root"),
            Self::Forbidden => (StatusCode::FORBIDDEN, "forbidden"),
            Self::NotStarted => (StatusCode::CONFLICT, "not_started"),
            Self::CodecUnavailable => (StatusCode::CONFLICT, "codec_unavailable"),
            Self::SetupFailed => (StatusCode::SERVICE_UNAVAILABLE, "setup_failed"),
            Self::NotFound => (StatusCode::NOT_FOUND, "not_found"),
        }
    }
}

#[derive(Clone)]
pub struct Snapshot {
    pub keys: KeySet,
    pub admissions_open: bool,
    pub max_ttl: Duration,
}

#[derive(Clone)]
#[derive(Debug)]
pub struct Checked {
    pub root: String,
    pub exp_unix: u64,
    pub operation: Op,
    pub broadcast: String,
    pub token: String,
}

pub struct Edge {
    snap: Mutex<Snapshot>,
    pool: Mutex<Pool>,
    dials: AtomicU64,
    /// Test double. Production leaves this false and `dial_relay` fails closed
    /// until a verified TLS dial is wired. Tests set it so a counted dial
    /// stands in for the relay connection.
    allow_test_dial: AtomicBool,
}

struct Pool {
    holds: HashMap<String, Hold>,
    sessions: HashMap<String, Session>,
    tombstones: HashMap<String, Tombstone>,
    next_id: u64,
    /// Tokens currently inside single-flight dial.
    inflight: HashMap<String, u32>,
}

struct Hold {
    refs: u32,
    exp_unix: u64,
}

struct Session {
    token: String,
    digest: [u8; 32],
}

struct Tombstone {
    digest: [u8; 32],
    until_unix: u64,
}

impl Edge {
    pub fn new(keys: KeySet) -> Arc<Self> {
        Arc::new(Self {
            snap: Mutex::new(Snapshot {
                keys,
                admissions_open: true,
                max_ttl: DEFAULT_MAX_TTL,
            }),
            pool: Mutex::new(Pool {
                holds: HashMap::new(),
                sessions: HashMap::new(),
                tombstones: HashMap::new(),
                next_id: 1,
                inflight: HashMap::new(),
            }),
            dials: AtomicU64::new(0),
            allow_test_dial: AtomicBool::new(false),
        })
    }

    pub fn enable_test_dial(&self) {
        self.allow_test_dial.store(true, Ordering::SeqCst);
    }

    pub fn dials(&self) -> u64 {
        self.dials.load(Ordering::SeqCst)
    }

    pub fn close_admissions(&self) {
        self.snap.lock().expect("snap").admissions_open = false;
    }

    pub fn refs(&self, token: &str) -> u32 {
        self.pool.lock().expect("pool").holds.get(token).map(|h| h.refs).unwrap_or(0)
    }

    pub fn session_count(&self) -> usize {
        self.pool.lock().expect("pool").sessions.len()
    }

    /// Reload verify keys only when the file and its directory pass
    /// `key_file_trusted` and `load_verify_keys`. A failure leaves the previous
    /// set installed and closes new admissions.
    pub fn reload_keys(&self, path: &std::path::Path) -> Result<(), anyhow::Error> {
        match key_file_trusted(path).and_then(|_| load_verify_keys(path)) {
            Ok(keys) => {
                let mut snap = self.snap.lock().expect("snap");
                snap.keys = keys;
                snap.admissions_open = true;
                Ok(())
            }
            Err(err) => {
                self.snap.lock().expect("snap").admissions_open = false;
                Err(err)
            }
        }
    }

    pub fn admit(
        &self,
        bearer: Option<&str>,
        header_root: Option<&str>,
        url_room: Option<&str>,
        operation: Op,
        broadcast_raw: &str,
        now: SystemTime,
    ) -> Result<Checked, AdmitError> {
        let token = bearer.map(str::trim).filter(|t| !t.is_empty()).ok_or(AdmitError::NoToken)?;
        let snap = self.snap.lock().expect("snap").clone();
        if !snap.admissions_open {
            return Err(AdmitError::BadToken);
        }
        let grant = assess(Some(token), "", &snap.keys, snap.max_ttl).map_err(map_refuse)?;
        let root = grant.root.clone().unwrap_or_default();
        let room = open_room(&root)?;
        if let Some(url_room) = url_room {
            if url_room != room {
                return Err(AdmitError::RoomNotOpen);
            }
        }
        match header_root {
            None => return Err(AdmitError::BadRequest),
            Some(header) if header != root => return Err(AdmitError::UnexpectedRoot),
            Some(_) => {}
        }
        let broadcast = canonical_broadcast(broadcast_raw, &root).map_err(|_| AdmitError::BadRequest)?;
        if !grant_matches(&grant, operation, &broadcast) {
            return Err(AdmitError::Forbidden);
        }
        let exp = grant.expires.ok_or(AdmitError::BadToken)?;
        let exp_unix = exp
            .checked_duration_since(kio::clock::Wall::UNIX_EPOCH)
            .ok_or(AdmitError::BadToken)?
            .as_secs();
        let now_unix = now.duration_since(UNIX_EPOCH).map_err(|_| AdmitError::BadToken)?.as_secs();
        if now_unix >= exp_unix {
            return Err(AdmitError::BadToken);
        }
        Ok(Checked {
            root,
            exp_unix,
            operation,
            broadcast,
            token: token.to_string(),
        })
    }

    /// Steps 9–14 for WHIP/WHEP. `/admit` must not call this.
    pub fn attach(
        &self,
        checked: &Checked,
        offer: &str,
        answer: &str,
        now: SystemTime,
    ) -> Result<String, AdmitError> {
        let now_unix = unix(now).map_err(|_| AdmitError::BadToken)?;
        let deadline = checked.exp_unix.min(now_unix.saturating_add(SETUP_BUDGET.as_secs()));
        if now_unix >= checked.exp_unix {
            self.drop_token(&checked.token);
            return Err(AdmitError::BadToken);
        }
        if now_unix >= deadline {
            return Err(AdmitError::SetupFailed);
        }
        self.acquire(&checked.token, checked.exp_unix)?;
        if offer_has_video(offer) && !answer_has_usable_video(answer) {
            self.release(&checked.token);
            return Err(AdmitError::CodecUnavailable);
        }
        let now_unix = unix(SystemTime::now()).unwrap_or(now_unix);
        if now_unix >= checked.exp_unix {
            self.drop_token(&checked.token);
            return Err(AdmitError::BadToken);
        }
        let mut pool = self.pool.lock().expect("pool");
        let id = pool.next_id.to_string();
        pool.next_id += 1;
        pool.sessions.insert(
            id.clone(),
            Session {
                token: checked.token.clone(),
                digest: digest(&checked.token),
            },
        );
        Ok(id)
    }

    fn acquire(&self, token: &str, exp_unix: u64) -> Result<(), AdmitError> {
        let mut pool = self.pool.lock().expect("pool");
        if let Some(hold) = pool.holds.get_mut(token) {
            hold.refs += 1;
            return Ok(());
        }
        let waiting = pool.inflight.entry(token.to_string()).or_insert(0);
        if *waiting > 0 {
            *waiting += 1;
            drop(pool);
            // The first dial owns the connection. A follower does not dial.
            let mut pool = self.pool.lock().expect("pool");
            pool.inflight.get_mut(token).map(|n| *n = n.saturating_sub(1));
            if let Some(hold) = pool.holds.get_mut(token) {
                hold.refs += 1;
                return Ok(());
            }
            return Err(AdmitError::SetupFailed);
        }
        *waiting = 1;
        drop(pool);
        let dialed = self.dial_relay(token);
        let mut pool = self.pool.lock().expect("pool");
        pool.inflight.remove(token);
        if !dialed {
            return Err(AdmitError::SetupFailed);
        }
        pool.holds.insert(
            token.to_string(),
            Hold { refs: 1, exp_unix },
        );
        Ok(())
    }

    fn dial_relay(&self, _token: &str) -> bool {
        self.dials.fetch_add(1, Ordering::SeqCst);
        self.allow_test_dial.load(Ordering::SeqCst)
    }

    fn release(&self, token: &str) {
        let mut pool = self.pool.lock().expect("pool");
        let gone = if let Some(hold) = pool.holds.get_mut(token) {
            hold.refs = hold.refs.saturating_sub(1);
            hold.refs == 0
        } else {
            false
        };
        if gone {
            pool.holds.remove(token);
        }
    }

    fn drop_token(&self, token: &str) {
        let mut pool = self.pool.lock().expect("pool");
        pool.holds.remove(token);
        pool.sessions.retain(|_, session| session.token != token);
    }

    pub fn delete(&self, id: &str, bearer: Option<&str>, now: SystemTime) -> Result<(), AdmitError> {
        let token = bearer.map(str::trim).filter(|t| !t.is_empty()).ok_or(AdmitError::NoToken)?;
        let dig = digest(token);
        let now_unix = unix(now).map_err(|_| AdmitError::BadToken)?;
        let mut pool = self.pool.lock().expect("pool");
        pool.tombstones.retain(|_, tomb| tomb.until_unix > now_unix);
        if let Some(session) = pool.sessions.get(id) {
            if session.digest != dig {
                return Err(AdmitError::Forbidden);
            }
            let token = session.token.clone();
            let until = pool.holds.get(&token).map(|h| h.exp_unix).unwrap_or(now_unix) + TOMBSTONE.as_secs();
            pool.sessions.remove(id);
            pool.tombstones.insert(
                id.to_string(),
                Tombstone { digest: dig, until_unix: until },
            );
            let gone = if let Some(hold) = pool.holds.get_mut(&token) {
                hold.refs = hold.refs.saturating_sub(1);
                hold.refs == 0
            } else {
                false
            };
            if gone {
                pool.holds.remove(&token);
            }
            return Ok(());
        }
        if let Some(tomb) = pool.tombstones.get(id) {
            if tomb.digest == dig && tomb.until_unix > now_unix {
                return Ok(());
            }
        }
        Err(AdmitError::NotFound)
    }

    pub fn router(self: &Arc<Self>) -> Router {
        Router::new()
            .route("/admit", post(admit_http))
            .route("/whip/{room}/{*broadcast}", post(whip_http))
            .route("/whep/{room}/{*broadcast}", post(whep_http))
            .route("/session/{id}", delete(delete_http))
            .with_state(self.clone())
    }
}

fn map_refuse(err: Refuse) -> AdmitError {
    match err {
        Refuse::NoToken => AdmitError::NoToken,
        _ => AdmitError::BadToken,
    }
}

fn unix(now: SystemTime) -> Result<u64, ()> {
    now.duration_since(UNIX_EPOCH).map(|d| d.as_secs()).map_err(|_| ())
}

fn digest(token: &str) -> [u8; 32] {
    Sha256::digest(token.as_bytes()).into()
}

/// Open only: `t/<canonical owner>/~open/<room>`. Anything else, including a
/// protected root and a wide `t/<owner>`, is `room_not_open`.
pub fn open_room(root: &str) -> Result<&str, AdmitError> {
    let parts: Vec<&str> = root.split('/').collect();
    if parts.len() != 4 || parts[0] != "t" || parts[2] != "~open" {
        return Err(AdmitError::RoomNotOpen);
    }
    if !crate::canonical_owner(parts[1]) || !room_segment(parts[3]) {
        return Err(AdmitError::RoomNotOpen);
    }
    Ok(parts[3])
}

fn room_segment(room: &str) -> bool {
    let n = room.len();
    (1..=64).contains(&n) && room.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

pub fn canonical_broadcast(raw: &str, root: &str) -> Result<String, ()> {
    if raw.contains('\\') || contains_forbidden_escape(raw) {
        return Err(());
    }
    let decoded = percent_decode_once(raw)?;
    if decoded.contains('\\') || contains_forbidden_escape(&decoded) || decoded.contains('%') {
        return Err(());
    }
    if decoded.is_empty() {
        return Err(());
    }
    for segment in decoded.split('/') {
        if segment.is_empty() || segment == "." || segment == ".." {
            return Err(());
        }
    }
    let full = format!("{root}/{decoded}");
    if full.len() > PATH_BOUND || full.split('/').count() > DEPTH_BOUND {
        return Err(());
    }
    Ok(decoded)
}

fn contains_forbidden_escape(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("%2f") || lower.contains("%5c")
}

fn percent_decode_once(raw: &str) -> Result<String, ()> {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return Err(());
            }
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).map_err(|_| ())?;
            let value = u8::from_str_radix(hex, 16).map_err(|_| ())?;
            out.push(value);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).map_err(|_| ())
}

fn grant_matches(grant: &Grant, operation: Op, broadcast: &str) -> bool {
    let Ok(pattern) = broadcast.parse::<Pattern>() else {
        return false;
    };
    let access = match operation {
        Op::Publish => &grant.publish,
        Op::Subscribe => &grant.subscribe,
    };
    access.path.contains(&pattern)
}

pub fn offer_has_video(sdp: &str) -> bool {
    sdp.lines().any(|line| {
        let line = line.trim();
        line.starts_with("m=video ") || line.starts_with("m=video\t")
    })
}

/// A usable video section has a non-zero port and is not `a=inactive`.
pub fn answer_has_usable_video(sdp: &str) -> bool {
    let mut in_video = false;
    let mut port_ok = false;
    let mut inactive = false;
    let mut saw = false;
    for line in sdp.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("m=") {
            if in_video && port_ok && !inactive {
                return true;
            }
            in_video = rest.starts_with("video ");
            port_ok = false;
            inactive = false;
            if in_video {
                saw = true;
                let mut parts = rest.split_whitespace();
                let _ = parts.next();
                port_ok = parts.next().is_some_and(|port| port != "0");
            }
        } else if in_video && line == "a=inactive" {
            inactive = true;
        }
    }
    saw && in_video && port_ok && !inactive
}

#[derive(Deserialize)]
struct AdmitBody {
    operation: String,
    broadcast: String,
}

async fn admit_http(
    State(edge): State<Arc<Edge>>,
    headers: HeaderMap,
    Json(body): Json<AdmitBody>,
) -> Response {
    let before = edge.dials();
    let op = match body.operation.as_str() {
        "publish" => Op::Publish,
        "subscribe" => Op::Subscribe,
        _ => return err(AdmitError::BadRequest),
    };
    match edge.admit(
        bearer(&headers),
        headers.get("x-mjolnir-root").and_then(|v| v.to_str().ok()),
        None,
        op,
        &body.broadcast,
        SystemTime::now(),
    ) {
        Ok(checked) => {
            debug_assert_eq!(edge.dials(), before);
            Json(json!({
                "root": checked.root,
                "exp": checked.exp_unix,
                "operation": body.operation,
                "broadcast": checked.broadcast,
            }))
            .into_response()
        }
        Err(error) => {
            debug_assert_eq!(edge.dials(), before);
            err(error)
        }
    }
}

async fn whip_http(
    State(edge): State<Arc<Edge>>,
    Path((room, broadcast)): Path<(String, String)>,
    headers: HeaderMap,
    body: String,
) -> Response {
    media_http(edge, Op::Publish, room, broadcast, headers, body).await
}

async fn whep_http(
    State(edge): State<Arc<Edge>>,
    Path((room, broadcast)): Path<(String, String)>,
    headers: HeaderMap,
    body: String,
) -> Response {
    media_http(edge, Op::Subscribe, room, broadcast, headers, body).await
}

async fn media_http(
    edge: Arc<Edge>,
    operation: Op,
    room: String,
    broadcast: String,
    headers: HeaderMap,
    offer: String,
) -> Response {
    let checked = match edge.admit(
        bearer(&headers),
        headers.get("x-mjolnir-root").and_then(|v| v.to_str().ok()),
        Some(room.as_str()),
        operation,
        &broadcast,
        SystemTime::now(),
    ) {
        Ok(checked) => checked,
        Err(error) => return err(error),
    };
    let answer = if offer_has_video(&offer) {
        "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=sendonly\r\n".to_string()
    } else {
        "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n".to_string()
    };
    match edge.attach(&checked, &offer, &answer, SystemTime::now()) {
        Ok(id) => Response::builder()
            .status(StatusCode::CREATED)
            .header("content-type", "application/sdp")
            .header("location", format!("/session/{id}"))
            .header("cache-control", "no-store")
            .body(axum::body::Body::from(answer))
            .unwrap(),
        Err(error) => err(error),
    }
}

async fn delete_http(
    State(edge): State<Arc<Edge>>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Response {
    match edge.delete(&id, bearer(&headers), SystemTime::now()) {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(error) => err(error),
    }
}

fn bearer(headers: &HeaderMap) -> Option<&str> {
    let value = headers.get("authorization")?.to_str().ok()?;
    value.strip_prefix("Bearer ").or_else(|| value.strip_prefix("bearer "))
}

fn err(error: AdmitError) -> Response {
    let (status, code) = error.status();
    (status, Json(json!({"error": code}))).into_response()
}

pub fn error_body(error: AdmitError) -> (StatusCode, Value) {
    let (status, code) = error.status();
    (status, json!({"error": code}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use moq_auth::{Algorithm, Claims, Key};

    fn owner() -> String {
        bs58::encode([9u8; 32]).into_string()
    }

    fn sign(publish: &str, subscribe: &str, root: &str, life: Duration) -> (KeySet, String) {
        let key = Key::generate(Algorithm::EdDSA, None).unwrap();
        let now = kio::clock::wall();
        let claims = Claims::default()
            .with_root(root)
            .with_publish([publish.parse().unwrap()])
            .with_subscribe([subscribe.parse().unwrap()])
            .with_issued(now)
            .with_expires(now + life);
        let token = key.sign(&claims).unwrap();
        let set = KeySet { keys: vec![std::sync::Arc::new(key.public().unwrap())] };
        (set, token)
    }

    fn mint_shaped_open() -> (KeySet, String, String) {
        let owner = owner();
        let root = format!("t/{owner}/~open/standup");
        // Same claim shape `Mjolnir.Relay.Mint.issue` writes for kind open:
        // publish `<participant>/**`, subscribe `**`, root `t/<owner>/~open/<room>`.
        let (set, token) = sign("alice/**", "**", &root, Duration::from_secs(600));
        (set, token, root)
    }

    #[test]
    fn parser_rejects_encoded_slash_backslash_and_dot_segments() {
        let root = "t/x/~open/r";
        assert!(canonical_broadcast("alice/cam", root).is_ok());
        assert!(canonical_broadcast("alice%2Fcam", root).is_err());
        assert!(canonical_broadcast("alice%2fcam", root).is_err());
        assert!(canonical_broadcast("alice%252fcam", root).is_err());
        assert!(canonical_broadcast("alice%5Ccam", root).is_err());
        assert!(canonical_broadcast(r"alice\cam", root).is_err());
        assert!(canonical_broadcast("alice/%2e%2e/cam", root).is_err());
        assert!(canonical_broadcast("./cam", root).is_err());
        assert!(canonical_broadcast("", root).is_err());
        let decoded = canonical_broadcast("alice%2Dcam", root).unwrap();
        assert_eq!(decoded, "alice-cam");
    }

    #[test]
    fn usable_video_rejects_port_zero_and_inactive() {
        assert!(answer_has_usable_video("m=video 9 UDP/TLS/RTP/SAVPF 96\na=sendrecv\n"));
        assert!(!answer_has_usable_video("m=video 0 UDP/TLS/RTP/SAVPF 96\n"));
        assert!(!answer_has_usable_video("m=video 9 UDP/TLS/RTP/SAVPF 96\na=inactive\n"));
        assert!(!answer_has_usable_video("m=audio 9 UDP/TLS/RTP/SAVPF 111\n"));
    }

    #[test]
    fn admit_open_mint_shape_does_not_dial_and_refuses_protected_and_wide() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        let ok = edge
            .admit(Some(&token), Some(&root), None, Op::Publish, "alice/cam", SystemTime::now())
            .unwrap();
        assert_eq!(ok.broadcast, "alice/cam");
        assert_eq!(edge.dials(), 0);
        let protected = format!("t/{}/standup", owner());
        let (set, token) = sign("alice/**", "**", &protected, Duration::from_secs(600));
        let edge = Edge::new(set);
        let err = edge
            .admit(Some(&token), Some("ignored"), None, Op::Publish, "alice/cam", SystemTime::now())
            .unwrap_err();
        assert_eq!(err, AdmitError::RoomNotOpen);
        assert_eq!(edge.dials(), 0);
        let wide = format!("t/{}", owner());
        let (set, token) = sign("**", "**", &wide, Duration::from_secs(60));
        let edge = Edge::new(set);
        assert_eq!(
            edge.admit(Some(&token), Some(&wide), None, Op::Publish, "alice/cam", SystemTime::now())
                .unwrap_err(),
            AdmitError::RoomNotOpen
        );
    }

    #[test]
    fn foreign_broadcast_header_mismatch_and_closed_admissions_do_not_dial() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        assert_eq!(
            edge.admit(Some(&token), Some(&root), None, Op::Publish, "bob/cam", SystemTime::now())
                .unwrap_err(),
            AdmitError::Forbidden
        );
        assert_eq!(
            edge.admit(Some(&token), Some("other"), None, Op::Publish, "alice/cam", SystemTime::now())
                .unwrap_err(),
            AdmitError::UnexpectedRoot
        );
        assert_eq!(
            edge.admit(None, Some(&root), None, Op::Publish, "alice/cam", SystemTime::now())
                .unwrap_err(),
            AdmitError::NoToken
        );
        edge.close_admissions();
        assert_eq!(
            edge.admit(Some(&token), Some(&root), None, Op::Publish, "alice/cam", SystemTime::now())
                .unwrap_err(),
            AdmitError::BadToken
        );
        assert_eq!(edge.dials(), 0);
    }

    #[test]
    fn two_legs_one_token_one_dial_and_delete_matrix() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        edge.enable_test_dial();
        let a = edge
            .admit(Some(&token), Some(&root), Some("standup"), Op::Publish, "alice/cam", SystemTime::now())
            .unwrap();
        let b = edge
            .admit(Some(&token), Some(&root), Some("standup"), Op::Subscribe, "alice/cam", SystemTime::now())
            .unwrap();
        let id_a = edge.attach(&a, "m=video 9 UDP/TLS/RTP/SAVPF 96\n", "m=video 9 UDP/TLS/RTP/SAVPF 96\n", SystemTime::now()).unwrap();
        let id_b = edge.attach(&b, "m=audio 9 UDP/TLS/RTP/SAVPF 111\n", "m=audio 9 UDP/TLS/RTP/SAVPF 111\n", SystemTime::now()).unwrap();
        assert_eq!(edge.dials(), 1);
        assert_eq!(edge.refs(&token), 2);
        let (set2, other, root2) = mint_shaped_open();
        let _ = (set2, root2);
        assert_eq!(edge.delete(&id_a, Some(&other), SystemTime::now()).unwrap_err(), AdmitError::Forbidden);
        assert_eq!(edge.refs(&token), 2);
        edge.delete(&id_a, Some(&token), SystemTime::now()).unwrap();
        edge.delete(&id_a, Some(&token), SystemTime::now()).unwrap();
        assert_eq!(edge.delete("missing", Some(&token), SystemTime::now()).unwrap_err(), AdmitError::NotFound);
        edge.delete(&id_b, Some(&token), SystemTime::now()).unwrap();
        assert_eq!(edge.refs(&token), 0);
        assert_eq!(
            edge.attach(
                &a,
                "m=video 9 UDP/TLS/RTP/SAVPF 96\n",
                "m=video 0 UDP/TLS/RTP/SAVPF 96\n",
                SystemTime::now()
            )
            .unwrap_err(),
            AdmitError::CodecUnavailable
        );
    }

    #[test]
    fn untrusted_key_file_closes_admissions_and_keeps_old_keys() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("keys.json");
        std::fs::write(&path, "not-keys").unwrap();
        assert!(edge.reload_keys(&path).is_err());
        assert_eq!(
            edge.admit(Some(&token), Some(&root), None, Op::Publish, "alice/cam", SystemTime::now())
                .unwrap_err(),
            AdmitError::BadToken
        );
    }
}
