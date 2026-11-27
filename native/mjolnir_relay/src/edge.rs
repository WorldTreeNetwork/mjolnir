//! Local WebRTC-edge admission. The process holds no mint key.
//! Each pooled relay connection is opened with that leg's own token.
//! `/admit` never dials.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::extract::{Path, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::middleware::{self, Next};
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
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
    pub keys_ok: bool,
    pub draining: bool,
    pub max_ttl: Duration,
    pub origins: Vec<String>,
}

impl Snapshot {
    pub fn admissions_open(&self) -> bool {
        self.keys_ok && !self.draining
    }
}

#[derive(Clone)]
pub struct Checked {
    pub root: String,
    /// Authenticated expiry, including the fractional second `assess` returned.
    pub exp: SystemTime,
    pub exp_unix: u64,
    pub operation: Op,
    pub broadcast: String,
    pub token: String,
}

impl std::fmt::Debug for Checked {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Checked")
            .field("root", &self.root)
            .field("exp_unix", &self.exp_unix)
            .field("operation", &self.operation)
            .field("broadcast", &self.broadcast)
            .field("token", &"<redacted>")
            .finish()
    }
}

pub struct Edge {
    snap: Mutex<Snapshot>,
    pool: Mutex<Pool>,
    dials: AtomicU64,
    draining: AtomicBool,
    allow_test_dial: AtomicBool,
    moq: Mutex<Option<crate::moq_session::MoqConfig>>,
    test_dial_wait: Mutex<Duration>,
    test_answer: Mutex<Option<String>>,
}

struct Pool {
    holds: HashMap<String, Hold>,
    sessions: HashMap<String, Session>,
    tombstones: HashMap<String, Tombstone>,
    next_id: u64,
    next_gen: u64,
    flights: HashMap<String, Arc<Flight>>,
    links: HashMap<String, Link>,
    runners: HashMap<String, tokio::task::JoinHandle<()>>,
    moq_paths: Vec<String>,
}

struct Flight {
    waiters: Mutex<Vec<tokio::sync::oneshot::Sender<Result<Reservation, AdmitError>>>>,
}

struct FlightGuard {
    edge: Arc<Edge>,
    token: String,
    flight: Arc<Flight>,
    armed: bool,
}

impl Drop for FlightGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let mut pool = self.edge.pool.lock().expect("pool");
        if pool.flights.get(&self.token).is_some_and(|flight| Arc::ptr_eq(flight, &self.flight)) {
            pool.flights.remove(&self.token);
        }
        // Dropping the flight senders wakes waiters with a closed channel so they retry
        // the remaining budget instead of inheriting the leader's cancellation.
    }
}

struct Hold {
    refs: u32,
    exp: SystemTime,
    /// Unix seconds of the grant expiry. Tombstones use the same instant plus 30s.
    #[allow(dead_code)]
    exp_unix: u64,
    generation: u64,
}

struct Link {
    generation: u64,
    shared: Option<Arc<crate::moq_session::Shared>>,
}

struct Session {
    token: String,
    digest: [u8; 32],
    generation: u64,
    exp_unix: u64,
    leg: Leg,
}

enum Leg {
    /// Admitted without an unrun RTC response (test attach), or already acknowledged.
    Settled,
    /// `Response::run` has not been called. Dropping this drops the unrun response.
    Pending {
        response: Option<moq_webrtc::server::Response>,
        /// Original setup deadline (`min(exp, setup_start+5s)`), not a fresh budget at ack.
        deadline: SystemTime,
    },
}

struct Tombstone {
    digest: [u8; 32],
    until_unix: u64,
}

/// One ref on one connection generation. Drop releases it exactly once.
struct Reservation {
    edge: Arc<Edge>,
    token: String,
    generation: u64,
    armed: bool,
}

impl Reservation {
    fn claim(edge: &Arc<Edge>, token: &str, generation: u64) -> Option<Self> {
        let mut pool = edge.pool.lock().expect("pool");
        let hold = pool.holds.get_mut(token)?;
        if hold.generation != generation {
            return None;
        }
        hold.refs = hold.refs.saturating_add(1);
        Some(Self {
            edge: Arc::clone(edge),
            token: token.to_string(),
            generation,
            armed: true,
        })
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for Reservation {
    fn drop(&mut self) {
        if self.armed {
            self.edge.release_gen(&self.token, self.generation);
        }
    }
}

enum Dialed {
    Live(crate::moq_session::Shared),
    Test,
}

impl Edge {
    pub fn new(keys: KeySet) -> Arc<Self> {
        Arc::new(Self {
            snap: Mutex::new(Snapshot {
                keys,
                keys_ok: true,
                draining: false,
                max_ttl: DEFAULT_MAX_TTL,
                origins: Vec::new(),
            }),
            pool: Mutex::new(Pool {
                holds: HashMap::new(),
                sessions: HashMap::new(),
                tombstones: HashMap::new(),
                next_id: 1,
                next_gen: 1,
                flights: HashMap::new(),
                links: HashMap::new(),
                runners: HashMap::new(),
                moq_paths: Vec::new(),
            }),
            dials: AtomicU64::new(0),
            draining: AtomicBool::new(false),
            allow_test_dial: AtomicBool::new(false),
            moq: Mutex::new(None),
            test_dial_wait: Mutex::new(Duration::from_millis(30)),
            test_answer: Mutex::new(None),
        })
    }

    pub fn set_moq(&self, config: crate::moq_session::MoqConfig) {
        *self.moq.lock().expect("moq") = Some(config);
    }

    pub fn set_max_ttl(&self, max_ttl: Duration) -> Result<(), ()> {
        if max_ttl.is_zero() {
            return Err(());
        }
        self.snap.lock().expect("snap").max_ttl = max_ttl;
        Ok(())
    }

    pub fn set_origins(&self, origins: Vec<String>) {
        self.snap.lock().expect("snap").origins = origins;
    }

    pub fn enable_test_dial(&self) {
        self.allow_test_dial.store(true, Ordering::SeqCst);
    }

    pub fn dials(&self) -> u64 {
        self.dials.load(Ordering::SeqCst)
    }

    pub fn moq_paths(&self) -> Vec<String> {
        self.pool.lock().expect("pool").moq_paths.clone()
    }

    pub fn close_admissions(&self) {
        self.snap.lock().expect("snap").keys_ok = false;
    }

    /// Emergency drain. Distinct from a bad key file: a later good reload does not reopen it.
    /// The flag is stored before the pool lock so an in-flight publish either is swept here
    /// or observes the flag in the same critical section that would insert its hold.
    pub fn drain(self: &Arc<Self>) {
        self.snap.lock().expect("snap").draining = true;
        self.draining.store(true, Ordering::SeqCst);
        let shareds = {
            let mut pool = self.pool.lock().expect("pool");
            let gens: Vec<(String, u64)> = pool.holds.iter().map(|(token, hold)| (token.clone(), hold.generation)).collect();
            let mut shareds = Vec::new();
            for (token, generation) in gens {
                if let Some(shared) = self.detach_locked(&mut pool, &token, generation) {
                    shareds.push(shared);
                }
            }
            let flights: Vec<Arc<Flight>> = pool.flights.drain().map(|(_, flight)| flight).collect();
            for flight in flights {
                for waiter in flight.waiters.lock().expect("waiters").drain(..) {
                    let _ = waiter.send(Err(AdmitError::SetupFailed));
                }
            }
            shareds
        };
        for shared in shareds {
            shared.close();
        }
    }

    pub fn admissions_open(&self) -> bool {
        self.snap.lock().expect("snap").admissions_open()
    }

    pub fn sweep(&self, now: SystemTime) {
        let expired: Vec<String> = {
            let pool = self.pool.lock().expect("pool");
            pool.holds
                .iter()
                .filter(|(_, hold)| now >= hold.exp)
                .map(|(token, _)| token.clone())
                .collect()
        };
        for token in expired {
            self.drop_token(&token);
        }
        let now_unix = unix(now).unwrap_or(0);
        self.pool.lock().expect("pool").tombstones.retain(|_, tomb| tomb.until_unix > now_unix);
    }

    pub async fn open_session(
        self: &Arc<Self>,
        checked: &Checked,
        offer: &str,
    ) -> Result<Negotiated, AdmitError> {
        let deadline = setup_deadline(checked.exp)?;
        let bound_at = if deadline.exp_bound {
            checked.exp
        } else {
            SystemTime::now() + SETUP_BUDGET
        };
        let mut reservation = self.acquire(&checked.token, checked.exp, &deadline).await?;
        let generation = reservation.generation;
        let shared = self
            .pool
            .lock()
            .expect("pool")
            .links
            .get(&checked.token)
            .and_then(|link| link.shared.clone());
        let Some(shared) = shared else {
            if self.allow_test_dial.load(Ordering::SeqCst) {
                self.pool.lock().expect("pool").moq_paths.push(checked.broadcast.clone());
                let id = {
                    let mut pool = self.pool.lock().expect("pool");
                    let id = pool.next_id.to_string();
                    pool.next_id += 1;
                    id
                };
                let answer = self.test_answer.lock().expect("answer").clone().unwrap_or_else(|| "v=0\r\n".into());
                self.insert_pending(&mut reservation, &id, checked, None, bound_at)
                    .map_err(|error| {
                        if error == AdmitError::BadToken {
                            reservation.disarm();
                            self.drop_token(&checked.token);
                        }
                        error
                    })?;
                reservation.disarm();
                self.arm_pending_deadline(&id, generation, bound_at);
                return Ok(Negotiated {
                    id,
                    answer,
                    generation,
                    edge: Arc::clone(self),
                    response: None,
                    armed: true,
                });
            }
            return Err(self.fail_setup(reservation, checked.exp, crate::moq_session::SetupFault::Other("no link".into())));
        };
        self.pool.lock().expect("pool").moq_paths.push(checked.broadcast.clone());
        let config = self.moq.lock().expect("moq").clone();
        let Some(config) = config else {
            return Err(self.fail_setup(reservation, checked.exp, crate::moq_session::SetupFault::Other("no moq".into())));
        };
        let moq_path = checked.broadcast.clone();
        let catalog = checked.operation == Op::Subscribe;
        let negotiate = async {
            match checked.operation {
                Op::Publish => crate::moq_session::whip(&config, &shared, &moq_path, offer).await,
                Op::Subscribe => crate::moq_session::whep(&config, &shared, &moq_path, offer).await,
            }
        };
        let closed = shared.closed();
        let negotiated = tokio::select! {
            biased;
            _ = tokio::time::sleep_until(deadline.at) => Err(crate::moq_session::SetupFault::Deadline { catalog }),
            _ = closed => Err(crate::moq_session::SetupFault::RelayClosed),
            result = negotiate => result,
        };
        let response = match negotiated {
            Ok(response) => response,
            Err(fault) => return Err(self.fail_setup(reservation, checked.exp, fault)),
        };
        if let Some(error) = self.finish_gate(checked, generation, &deadline, catalog) {
            drop(response);
            reservation.disarm();
            if error == AdmitError::BadToken {
                self.drop_token(&checked.token);
            } else {
                reservation.armed = true;
            }
            return Err(error);
        }
        if offer_has_video(offer) && !answer_has_usable_video(&response.answer) {
            drop(response);
            return Err(self.fail_setup(reservation, checked.exp, crate::moq_session::SetupFault::Other("codec".into()))
                .max_codec(checked.exp));
        }
        let id = response.resource_id.clone();
        let answer = response.answer.clone();
        self.insert_pending(&mut reservation, &id, checked, Some(response), bound_at)
            .map_err(|error| {
                if error == AdmitError::BadToken {
                    reservation.disarm();
                    self.drop_token(&checked.token);
                }
                error
            })?;
        reservation.disarm();
        self.arm_pending_deadline(&id, generation, bound_at);
        Ok(Negotiated {
            id,
            answer,
            generation,
            edge: Arc::clone(self),
            response: None,
            armed: true,
        })
    }

    fn fail_setup(
        &self,
        mut reservation: Reservation,
        exp: SystemTime,
        fault: crate::moq_session::SetupFault,
    ) -> AdmitError {
        let token = reservation.token.clone();
        let error = self.classify(&token, exp, &fault);
        if error == AdmitError::BadToken {
            reservation.disarm();
            self.drop_token(&token);
        }
        error
    }

    fn finish_gate(&self, checked: &Checked, generation: u64, deadline: &Deadline, catalog: bool) -> Option<AdmitError> {
        if SystemTime::now() >= checked.exp || (deadline.exp_bound && tokio::time::Instant::now() >= deadline.at) {
            return Some(AdmitError::BadToken);
        }
        if tokio::time::Instant::now() >= deadline.at {
            return Some(if catalog { AdmitError::NotStarted } else { AdmitError::SetupFailed });
        }
        let current = self.pool.lock().expect("pool").holds.get(&checked.token).map(|hold| hold.generation);
        if current != Some(generation) {
            return Some(AdmitError::SetupFailed);
        }
        let dead = self
            .pool
            .lock()
            .expect("pool")
            .links
            .get(&checked.token)
            .and_then(|link| link.shared.as_ref())
            .is_some_and(|shared| shared.dead());
        if dead {
            return Some(AdmitError::SetupFailed);
        }
        None
    }

    fn classify(&self, token: &str, exp: SystemTime, fault: &crate::moq_session::SetupFault) -> AdmitError {
        if SystemTime::now() >= exp {
            self.drop_token(token);
            return AdmitError::BadToken;
        }
        match fault {
            crate::moq_session::SetupFault::Catalog | crate::moq_session::SetupFault::Deadline { catalog: true } => {
                AdmitError::NotStarted
            }
            crate::moq_session::SetupFault::Other(text) if text == "codec" => AdmitError::CodecUnavailable,
            _ => AdmitError::SetupFailed,
        }
    }

    pub fn refs(&self, token: &str) -> u32 {
        self.pool.lock().expect("pool").holds.get(token).map(|hold| hold.refs).unwrap_or(0)
    }

    pub fn session_count(&self) -> usize {
        self.pool.lock().expect("pool").sessions.len()
    }

    pub fn reload_keys(&self, path: &std::path::Path) -> Result<(), anyhow::Error> {
        match key_file_trusted(path).and_then(|_| load_verify_keys(path)) {
            Ok(keys) => {
                let mut snap = self.snap.lock().expect("snap");
                snap.keys = keys;
                snap.keys_ok = true;
                Ok(())
            }
            Err(err) => {
                self.snap.lock().expect("snap").keys_ok = false;
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
        let pre = self.admit_identity(bearer, header_root, url_room, now)?;
        self.admit_broadcast(pre, operation, broadcast_raw, now)
    }

    fn admit_identity(
        &self,
        bearer: Option<&str>,
        header_root: Option<&str>,
        url_room: Option<&str>,
        now: SystemTime,
    ) -> Result<PreAdmit, AdmitError> {
        let token = bearer.map(str::trim).filter(|token| !token.is_empty()).ok_or(AdmitError::NoToken)?;
        self.sweep(now);
        let snap = self.snap.lock().expect("snap").clone();
        if !snap.admissions_open() {
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
        Ok(PreAdmit { grant, root, token: token.to_string() })
    }

    fn admit_broadcast(&self, pre: PreAdmit, operation: Op, broadcast_raw: &str, now: SystemTime) -> Result<Checked, AdmitError> {
        let broadcast = canonical_broadcast(broadcast_raw, &pre.root).map_err(|_| AdmitError::BadRequest)?;
        if !grant_matches(&pre.grant, operation, &broadcast) {
            return Err(AdmitError::Forbidden);
        }
        let exp_wall = pre.grant.expires.ok_or(AdmitError::BadToken)?;
        let since = exp_wall
            .checked_duration_since(kio::clock::Wall::UNIX_EPOCH)
            .ok_or(AdmitError::BadToken)?;
        let exp = UNIX_EPOCH + since;
        if now >= exp {
            return Err(AdmitError::BadToken);
        }
        Ok(Checked {
            root: pre.root,
            exp,
            exp_unix: since.as_secs(),
            operation,
            broadcast,
            token: pre.token,
        })
    }

    pub async fn attach(
        self: &Arc<Self>,
        checked: &Checked,
        offer: &str,
        answer: &str,
        now: SystemTime,
    ) -> Result<String, AdmitError> {
        if now >= checked.exp {
            self.drop_token(&checked.token);
            return Err(AdmitError::BadToken);
        }
        let deadline = setup_deadline(checked.exp)?;
        let mut reservation = self.acquire(&checked.token, checked.exp, &deadline).await?;
        if let Some(error) = self.finish_gate(checked, reservation.generation, &deadline, false) {
            reservation.disarm();
            if error == AdmitError::BadToken {
                self.drop_token(&checked.token);
            }
            return Err(error);
        }
        if offer_has_video(offer) && !answer_has_usable_video(answer) {
            if SystemTime::now() >= checked.exp {
                reservation.disarm();
                self.drop_token(&checked.token);
                return Err(AdmitError::BadToken);
            }
            return Err(AdmitError::CodecUnavailable);
        }
        let id = {
            let mut pool = self.pool.lock().expect("pool");
            let id = pool.next_id.to_string();
            pool.next_id += 1;
            id
        };
        self.commit_session(&mut reservation, &id, checked)?;
        Ok(id)
    }

    /// Insert, or on expiry drop the whole generation. A drain or generation miss leaves the reservation armed so its Drop releases only its own ref.
    fn commit_session(&self, reservation: &mut Reservation, id: &str, checked: &Checked) -> Result<(), AdmitError> {
        if let Err(error) = self.insert_session(reservation, id, checked) {
            if error == AdmitError::BadToken {
                reservation.disarm();
                self.drop_token(&checked.token);
            }
            return Err(error);
        }
        reservation.disarm();
        Ok(())
    }

    /// Generation, expiry, and drain are decided in the same critical section as the insert.
    fn insert_session(&self, reservation: &Reservation, id: &str, checked: &Checked) -> Result<(), AdmitError> {
        let mut pool = self.pool.lock().expect("pool");
        if self.draining.load(Ordering::SeqCst) {
            return Err(AdmitError::SetupFailed);
        }
        if SystemTime::now() >= checked.exp {
            return Err(AdmitError::BadToken);
        }
        match pool.holds.get(&checked.token) {
            Some(hold) if hold.generation == reservation.generation => {}
            _ => return Err(AdmitError::SetupFailed),
        }
        pool.sessions.insert(
            id.to_string(),
            Session {
                token: checked.token.clone(),
                digest: digest(&checked.token),
                generation: reservation.generation,
                exp_unix: checked.exp_unix,
                leg: Leg::Settled,
            },
        );
        Ok(())
    }

    /// Same critical section as `insert_session`, holding the unrun response until HTTP ack.
    fn insert_pending(
        &self,
        reservation: &Reservation,
        id: &str,
        checked: &Checked,
        response: Option<moq_webrtc::server::Response>,
        deadline: SystemTime,
    ) -> Result<(), AdmitError> {
        let mut pool = self.pool.lock().expect("pool");
        if self.draining.load(Ordering::SeqCst) {
            return Err(AdmitError::SetupFailed);
        }
        if SystemTime::now() >= checked.exp || SystemTime::now() >= deadline {
            return Err(AdmitError::BadToken);
        }
        match pool.holds.get(&checked.token) {
            Some(hold) if hold.generation == reservation.generation => {}
            _ => return Err(AdmitError::SetupFailed),
        }
        let dead = pool
            .links
            .get(&checked.token)
            .and_then(|link| link.shared.as_ref())
            .is_some_and(|shared| shared.dead());
        if dead {
            return Err(AdmitError::SetupFailed);
        }
        pool.sessions.insert(
            id.to_string(),
            Session {
                token: checked.token.clone(),
                digest: digest(&checked.token),
                generation: reservation.generation,
                exp_unix: checked.exp_unix,
                leg: Leg::Pending { response, deadline },
            },
        );
        Ok(())
    }

    fn arm_pending_deadline(self: &Arc<Self>, id: &str, generation: u64, deadline: SystemTime) {
        let edge = Arc::clone(self);
        let id = id.to_string();
        tokio::spawn(async move {
            if let Ok(wait) = deadline.duration_since(SystemTime::now()) {
                tokio::time::sleep(wait).await;
            }
            edge.cancel_delivery(&id, generation);
        });
    }

    /// Start the parked runner, or return false and leave a stale id untouched.
    /// On a still-pending session that fails drain, expiry, deadline, or relay
    /// liveness, the unrun response is dropped and the candidate is finished.
    pub(crate) fn ack_delivery(self: &Arc<Self>, id: &str, generation: u64) -> bool {
        let started = {
            let mut pool = self.pool.lock().expect("pool");
            let Some(session) = pool.sessions.get(id) else {
                return false;
            };
            if session.generation != generation {
                return false;
            }
            if !matches!(session.leg, Leg::Pending { .. }) {
                return true;
            }
            let token = session.token.clone();
            let exp_unix = session.exp_unix;
            let deadline = match &session.leg {
                Leg::Pending { deadline, .. } => *deadline,
                Leg::Settled => return true,
            };
            let now_unix = unix(SystemTime::now()).unwrap_or(u64::MAX);
            let dead = pool
                .links
                .get(&token)
                .and_then(|link| link.shared.as_ref())
                .is_some_and(|shared| shared.dead());
            let stale = self.draining.load(Ordering::SeqCst)
                || now_unix >= exp_unix
                || SystemTime::now() >= deadline
                || dead;
            let Leg::Pending { response, .. } = &mut pool.sessions.get_mut(id).expect("session").leg else {
                return true;
            };
            let response = response.take();
            if stale {
                drop(pool);
                drop(response);
                self.finish_id(id, generation, true);
                return false;
            }
            pool.sessions.get_mut(id).expect("session").leg = Leg::Settled;
            if let Some(response) = response {
                let edge = Arc::clone(self);
                let run_id = id.to_string();
                let (gate, opened) = tokio::sync::oneshot::channel::<()>();
                let task = tokio::spawn(async move {
                    let _ = opened.await;
                    let _ = response.run().await;
                    edge.finish_id(&run_id, generation, false);
                });
                pool.runners.insert(id.to_string(), task);
                Some(gate)
            } else {
                None
            }
        };
        if let Some(gate) = started {
            let _ = gate.send(());
        }
        true
    }

    /// Pending candidates only. An acknowledged session stays up.
    pub(crate) fn cancel_delivery(&self, id: &str, generation: u64) {
        let pending = {
            let pool = self.pool.lock().expect("pool");
            pool.sessions.get(id).is_some_and(|session| {
                session.generation == generation && matches!(session.leg, Leg::Pending { .. })
            })
        };
        if pending {
            self.finish_id(id, generation, true);
        }
    }

    async fn acquire(
        self: &Arc<Self>,
        token: &str,
        exp: SystemTime,
        deadline: &Deadline,
    ) -> Result<Reservation, AdmitError> {
        loop {
            if SystemTime::now() >= exp {
                self.drop_token(token);
                return Err(AdmitError::BadToken);
            }
            if tokio::time::Instant::now() >= deadline.at {
                return Err(self.timeout_error(token, exp, deadline.exp_bound));
            }
            enum Step {
                Ready(Reservation),
                Follow(tokio::sync::oneshot::Receiver<Result<Reservation, AdmitError>>),
                Lead(Arc<Flight>),
            }
            let step = {
                let mut pool = self.pool.lock().expect("pool");
                let generation = pool.holds.get(token).map(|hold| hold.generation);
                let dead = pool
                    .links
                    .get(token)
                    .and_then(|link| link.shared.as_ref())
                    .is_some_and(|shared| shared.dead());
                if let Some(generation) = generation {
                    if dead {
                        Step::Lead(Arc::new(Flight { waiters: Mutex::new(Vec::new()) }))
                    } else {
                        pool.holds.get_mut(token).expect("hold").refs += 1;
                        Step::Ready(Reservation {
                            edge: Arc::clone(self),
                            token: token.to_string(),
                            generation,
                            armed: true,
                        })
                    }
                } else if let Some(existing) = pool.flights.get(token) {
                    let (tx, rx) = tokio::sync::oneshot::channel();
                    existing.waiters.lock().expect("waiters").push(tx);
                    Step::Follow(rx)
                } else {
                    let flight = Arc::new(Flight { waiters: Mutex::new(Vec::new()) });
                    pool.flights.insert(token.to_string(), flight.clone());
                    Step::Lead(flight)
                }
            };
            match step {
                Step::Ready(reservation) => return Ok(reservation),
                Step::Follow(rx) => {
                    match self.follow(token, exp, rx, deadline).await {
                        Ok(reservation) => return Ok(reservation),
                        Err(FollowEnd::Retry) => continue,
                        Err(FollowEnd::Fail(error)) => return Err(error),
                    }
                }
                Step::Lead(flight) => {
                    let existing = self.pool.lock().expect("pool").flights.get(token).cloned();
                    if let Some(existing) = existing {
                        if !Arc::ptr_eq(&existing, &flight) {
                            let (tx, rx) = tokio::sync::oneshot::channel();
                            existing.waiters.lock().expect("waiters").push(tx);
                            match self.follow(token, exp, rx, deadline).await {
                                Ok(reservation) => return Ok(reservation),
                                Err(FollowEnd::Retry) => continue,
                                Err(FollowEnd::Fail(error)) => return Err(error),
                            }
                        }
                    } else {
                        self.pool.lock().expect("pool").flights.insert(token.to_string(), flight.clone());
                    }
                    return self.lead(token, exp, deadline, flight).await;
                }
            }
        }
    }

    async fn follow(
        &self,
        token: &str,
        exp: SystemTime,
        mut rx: tokio::sync::oneshot::Receiver<Result<Reservation, AdmitError>>,
        deadline: &Deadline,
    ) -> Result<Reservation, FollowEnd> {
        tokio::select! {
            biased;
            result = &mut rx => match result {
                Ok(Ok(reservation)) => {
                    if SystemTime::now() >= exp {
                        drop(reservation);
                        self.drop_token(token);
                        Err(FollowEnd::Fail(AdmitError::BadToken))
                    } else {
                        Ok(reservation)
                    }
                }
                Ok(Err(error)) => Err(FollowEnd::Fail(error)),
                Err(_) => Err(FollowEnd::Retry),
            },
            _ = tokio::time::sleep_until(deadline.at) => {
                Err(FollowEnd::Fail(self.timeout_error(token, exp, deadline.exp_bound)))
            },
        }
    }

    async fn lead(
        self: &Arc<Self>,
        token: &str,
        exp: SystemTime,
        deadline: &Deadline,
        flight: Arc<Flight>,
    ) -> Result<Reservation, AdmitError> {
        let mut guard = FlightGuard {
            edge: Arc::clone(self),
            token: token.to_string(),
            flight,
            armed: true,
        };
        let budget = deadline.at.saturating_duration_since(tokio::time::Instant::now());
        let dialed = tokio::select! {
            biased;
            _ = tokio::time::sleep_until(deadline.at) => Err(self.timeout_error(token, exp, deadline.exp_bound)),
            result = self.dial_relay(token, budget) => result,
        };
        let expired = SystemTime::now() >= exp
            || (deadline.exp_bound && tokio::time::Instant::now() >= deadline.at);
        // drop_token takes the pool mutex. Classify expiry before that lock.
        let dialed = match dialed {
            Ok(_) if expired => Err(self.timeout_error(token, exp, true)),
            Err(error) if expired && error != AdmitError::BadToken => {
                Err(self.timeout_error(token, exp, deadline.exp_bound || SystemTime::now() >= exp))
            }
            other => other,
        };
        guard.armed = false;
        let generation = {
            let mut pool = self.pool.lock().expect("pool");
            let owns_flight = pool.flights.get(token).is_some_and(|flight| Arc::ptr_eq(flight, &guard.flight));
            if self.draining.load(Ordering::SeqCst) || !owns_flight {
                if owns_flight {
                    pool.flights.remove(token);
                }
                for waiter in guard.flight.waiters.lock().expect("waiters").drain(..) {
                    let _ = waiter.send(Err(AdmitError::SetupFailed));
                }
                if let Ok(Dialed::Live(shared)) = &dialed {
                    shared.close();
                }
                return Err(AdmitError::SetupFailed);
            }
            pool.flights.remove(token);
            match dialed {
                Ok(dialed) => {
                    let generation = pool.next_gen;
                    pool.next_gen = pool.next_gen.saturating_add(1);
                    let exp_unix = exp.duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
                    pool.holds.insert(
                        token.to_string(),
                        Hold { refs: 0, exp, exp_unix, generation },
                    );
                    pool.links.insert(
                        token.to_string(),
                        Link {
                            generation,
                            shared: match dialed {
                                Dialed::Live(shared) => Some(Arc::new(shared)),
                                Dialed::Test => None,
                            },
                        },
                    );
                    generation
                }
                Err(error) => {
                    for waiter in guard.flight.waiters.lock().expect("waiters").drain(..) {
                        let _ = waiter.send(Err(error));
                    }
                    return Err(error);
                }
            }
        };
        if let Some(conn) = self.pool.lock().expect("pool").links.get(token).and_then(|link| link.shared.as_ref().map(|shared| shared.connection())) {
            let edge = Arc::clone(self);
            let watched = token.to_string();
            tokio::spawn(async move {
                let _ = conn.closed().await;
                edge.drop_token_gen(&watched, generation);
            });
        }
        let edge = Arc::clone(self);
        let watched = token.to_string();
        tokio::spawn(async move {
            if let Ok(wait) = exp.duration_since(SystemTime::now()) {
                tokio::time::sleep(wait).await;
            }
            edge.drop_token_gen(&watched, generation);
        });
        let mine = Reservation::claim(self, token, generation).ok_or(AdmitError::SetupFailed)?;
        let waiters = guard.flight.waiters.lock().expect("waiters").drain(..).collect::<Vec<_>>();
        for waiter in waiters {
            match Reservation::claim(self, token, generation) {
                Some(reservation) => {
                    let _ = waiter.send(Ok(reservation));
                }
                None => {
                    let _ = waiter.send(Err(AdmitError::SetupFailed));
                }
            }
        }
        Ok(mine)
    }

    fn timeout_error(&self, token: &str, exp: SystemTime, exp_bound: bool) -> AdmitError {
        if exp_bound || SystemTime::now() >= exp {
            self.drop_token(token);
            AdmitError::BadToken
        } else {
            AdmitError::SetupFailed
        }
    }

    async fn dial_relay(&self, token: &str, budget: Duration) -> Result<Dialed, AdmitError> {
        self.dials.fetch_add(1, Ordering::SeqCst);
        let config = self.moq.lock().expect("moq").clone();
        if let Some(config) = config {
            let shared = crate::moq_session::dial(&config, token, budget).await.map_err(|err| {
                tracing::warn!(%err, "relay dial failed");
                AdmitError::SetupFailed
            })?;
            return Ok(Dialed::Live(shared));
        }
        if self.allow_test_dial.load(Ordering::SeqCst) {
            let wait = *self.test_dial_wait.lock().expect("wait");
            // The caller's select owns the deadline. Capping this sleep to `budget`
            // and then returning Ok finishes a hair before the deadline and admits
            // a token that has already expired.
            let _ = budget;
            tokio::time::sleep(wait).await;
            return Ok(Dialed::Test);
        }
        Err(AdmitError::SetupFailed)
    }

    fn release_gen(&self, token: &str, generation: u64) {
        let shared = {
            let mut pool = self.pool.lock().expect("pool");
            release_locked(&mut pool, token, generation)
        };
        if let Some(shared) = shared {
            shared.close();
        }
    }

    fn runner_finished(pool: &mut Pool) {
        pool.runners.retain(|_, task| !task.is_finished());
    }

    fn end_runner(&self, pool: &mut Pool, id: &str) {
        if let Some(config) = self.moq.lock().expect("moq").clone() {
            config.media.terminate(id);
        }
        if let Some(task) = pool.runners.remove(id) {
            task.abort();
        }
    }

    fn drop_token_gen(&self, token: &str, generation: u64) {
        let shared = {
            let mut pool = self.pool.lock().expect("pool");
            self.detach_locked(&mut pool, token, generation)
        };
        if let Some(shared) = shared {
            shared.close();
        }
    }

    fn drop_token(&self, token: &str) {
        let generation = self.pool.lock().expect("pool").holds.get(token).map(|hold| hold.generation);
        if let Some(generation) = generation {
            self.drop_token_gen(token, generation);
        }
    }

    /// Validate and detach one generation, including its sessions, under one pool lock.
    fn detach_locked(&self, pool: &mut Pool, token: &str, generation: u64) -> Option<Arc<crate::moq_session::Shared>> {
        let matches = pool.holds.get(token).is_some_and(|hold| hold.generation == generation);
        if !matches {
            return None;
        }
        let ids: Vec<String> = pool
            .sessions
            .iter()
            .filter(|(_, session)| session.token == token && session.generation == generation)
            .map(|(id, _)| id.clone())
            .collect();
        let legs = ids.len();
        for id in &ids {
            let Some(session) = pool.sessions.remove(id) else { continue };
            let until = session.exp_unix.saturating_add(TOMBSTONE.as_secs());
            pool.tombstones.insert(id.clone(), Tombstone { digest: session.digest, until_unix: until });
            self.end_runner(pool, id);
        }
        pool.holds.remove(token);
        let shared = if pool.links.get(token).is_some_and(|link| link.generation == generation) {
            pool.links.remove(token).and_then(|link| link.shared)
        } else {
            None
        };
        tracing::info!(
            legs,
            sessions = pool.sessions.len(),
            runners = pool.runners.len(),
            links = pool.links.len(),
            "expired token dropped"
        );
        shared
    }

    fn finish_id(&self, id: &str, generation: u64, abort_runner: bool) {
        let mut pool = self.pool.lock().expect("pool");
        let Some(session) = pool.sessions.get(id) else {
            return;
        };
        if session.generation != generation {
            return;
        }
        let token = session.token.clone();
        let digest = session.digest;
        let until = session.exp_unix.saturating_add(TOMBSTONE.as_secs());
        pool.sessions.remove(id);
        if abort_runner {
            self.end_runner(&mut pool, id);
        } else {
            pool.runners.remove(id);
        }
        pool.tombstones.insert(id.to_string(), Tombstone { digest, until_unix: until });
        let shared = release_locked(&mut pool, &token, generation);
        let sessions = pool.sessions.len();
        let runners = pool.runners.len();
        let links = pool.links.len();
        drop(pool);
        if let Some(shared) = shared {
            shared.close();
        }
        tracing::info!(sessions, runners, links, "session finished");
    }

    pub fn runner_count(&self) -> usize {
        let mut pool = self.pool.lock().expect("pool");
        Self::runner_finished(&mut pool);
        pool.runners.len()
    }

    pub fn flight_count(&self) -> usize {
        self.pool.lock().expect("pool").flights.len()
    }

    pub fn link_count(&self) -> usize {
        self.pool.lock().expect("pool").links.len()
    }

    pub fn tombstone_count(&self) -> usize {
        self.pool.lock().expect("pool").tombstones.len()
    }

    pub fn delete(&self, id: &str, bearer: Option<&str>, now: SystemTime) -> Result<(), AdmitError> {
        let token = bearer.map(str::trim).filter(|token| !token.is_empty()).ok_or(AdmitError::NoToken)?;
        let dig = digest(token);
        let now_unix = unix(now).map_err(|_| AdmitError::BadToken)?;
        self.pool.lock().expect("pool").tombstones.retain(|_, tomb| tomb.until_unix > now_unix);
        let generation = self.pool.lock().expect("pool").sessions.get(id).map(|session| session.generation);
        if let Some(generation) = generation {
            let session_digest = self.pool.lock().expect("pool").sessions.get(id).map(|session| session.digest);
            if session_digest != Some(dig) {
                return Err(AdmitError::Forbidden);
            }
            self.finish_id(id, generation, true);
            return Ok(());
        }
        let pool = self.pool.lock().expect("pool");
        if let Some(tomb) = pool.tombstones.get(id) {
            if tomb.until_unix > now_unix {
                if tomb.digest == dig {
                    return Ok(());
                }
                return Err(AdmitError::Forbidden);
            }
        }
        Err(AdmitError::NotFound)
    }

    pub fn router(self: &Arc<Self>) -> Router {
        Router::new()
            .route("/admit", post(admit_http))
            .route("/whip/{*path}", post(whip_http))
            .route("/whep/{*path}", post(whep_http))
            .route("/session/{id}", delete(delete_http))
            .layer(middleware::from_fn_with_state(Arc::clone(self), cors))
            .with_state(Arc::clone(self))
    }
}

fn release_locked(pool: &mut Pool, token: &str, generation: u64) -> Option<Arc<crate::moq_session::Shared>> {
    let gone = if let Some(hold) = pool.holds.get_mut(token) {
        if hold.generation != generation {
            return None;
        }
        hold.refs = hold.refs.saturating_sub(1);
        hold.refs == 0
    } else {
        false
    };
    if gone {
        pool.holds.remove(token);
        if pool.links.get(token).is_some_and(|link| link.generation == generation) {
            return pool.links.remove(token).and_then(|link| link.shared);
        }
    }
    None
}

struct PreAdmit {
    grant: Grant,
    root: String,
    token: String,
}

enum FollowEnd {
    Retry,
    Fail(AdmitError),
}

trait CodecRank {
    fn max_codec(self, exp: SystemTime) -> Self;
}

impl CodecRank for AdmitError {
    fn max_codec(self, exp: SystemTime) -> Self {
        if SystemTime::now() >= exp {
            AdmitError::BadToken
        } else if self == AdmitError::SetupFailed {
            AdmitError::CodecUnavailable
        } else {
            self
        }
    }
}

/// An accepted answer. The RTC runner stays parked until HTTP/1 flush ack.
pub struct Negotiated {
    id: String,
    answer: String,
    generation: u64,
    edge: Arc<Edge>,
    response: Option<moq_webrtc::server::Response>,
    armed: bool,
}

impl Drop for Negotiated {
    fn drop(&mut self) {
        if self.armed {
            self.response.take();
            self.edge.finish_id(&self.id, self.generation, true);
        }
    }
}

impl Negotiated {
    fn queue(mut self) -> (String, String, RunGuard, Option<moq_webrtc::server::Response>) {
        let response = self.response.take();
        self.armed = false;
        let id = self.id.clone();
        let answer = self.answer.clone();
        let guard = RunGuard {
            edge: Arc::clone(&self.edge),
            id: id.clone(),
            generation: self.generation,
            armed: true,
        };
        (id, answer, guard, response)
    }
}

struct RunGuard {
    edge: Arc<Edge>,
    id: String,
    generation: u64,
    armed: bool,
}

impl Drop for RunGuard {
    fn drop(&mut self) {
        if self.armed {
            self.edge.finish_id(&self.id, self.generation, true);
        }
    }
}

struct Deadline {
    at: tokio::time::Instant,
    /// The bound is token expiry, so firing it is `bad_token` even if the clock is a hair early.
    exp_bound: bool,
}

fn setup_deadline(exp: SystemTime) -> Result<Deadline, AdmitError> {
    let now = SystemTime::now();
    if now >= exp {
        return Err(AdmitError::BadToken);
    }
    let remaining = exp.duration_since(now).unwrap_or(Duration::ZERO);
    let exp_bound = remaining <= SETUP_BUDGET;
    let budget = if exp_bound { remaining } else { SETUP_BUDGET };
    Ok(Deadline { at: tokio::time::Instant::now() + budget, exp_bound })
}

fn queue_http(edge: Arc<Edge>, negotiated: Negotiated, extensions: &axum::http::Extensions) -> Response {
    let (id, answer, guard, _response) = negotiated.queue();
    // The negotiated guard must not finish the candidate; the body and the
    // connection own cancellation until flush ack. Disarm it.
    let generation = guard.generation;
    guard_disarm(guard);
    let Some(ctx) = extensions.get::<crate::edge_http::DeliveryContext>().cloned() else {
        // No delivery context: do not pretend the answer was accepted.
        edge.cancel_delivery(&id, generation);
        return err(AdmitError::SetupFailed);
    };
    let body = axum::body::Body::new(crate::edge_http::AnswerBody::new(
        answer,
        edge,
        id.clone(),
        generation,
        ctx,
    ));
    // No Content-Length. An exact length lets Hyper finish the body without polling EOF.
    Response::builder()
        .status(StatusCode::CREATED)
        .header("content-type", "application/sdp")
        .header("location", format!("/session/{id}"))
        .header("cache-control", "no-store")
        .body(body)
        .unwrap()
}

fn guard_disarm(mut guard: RunGuard) {
    guard.armed = false;
}

async fn cors(
    State(edge): State<Arc<Edge>>,
    req: axum::extract::Request,
    next: Next,
) -> Response {
    let origin = req.headers().get("origin").and_then(|value| value.to_str().ok()).map(str::to_string);
    let host = req.headers().get("host").and_then(|value| value.to_str().ok()).unwrap_or("").to_string();
    let allowed = origin.as_deref().is_some_and(|origin| origin_allowed(&edge, origin, &host));
    let response = if req.method() == axum::http::Method::OPTIONS {
        StatusCode::NO_CONTENT.into_response()
    } else {
        next.run(req).await
    };
    cors_headers(response, origin.as_deref(), allowed)
}

fn origin_allowed(edge: &Edge, origin: &str, host: &str) -> bool {
    let snap = edge.snap.lock().expect("snap");
    if !snap.origins.is_empty() {
        return snap.origins.iter().any(|allowed| allowed == origin);
    }
    if host.is_empty() {
        return false;
    }
    // This listener is plain HTTP. An empty list is that one scheme plus this host, not both schemes.
    origin == format!("http://{host}")
}

fn cors_headers(mut response: Response, origin: Option<&str>, allowed: bool) -> Response {
    let headers = response.headers_mut();
    headers.insert("vary", HeaderValue::from_static("origin"));
    headers.insert(
        "access-control-allow-methods",
        HeaderValue::from_static("POST,DELETE,OPTIONS"),
    );
    headers.insert(
        "access-control-allow-headers",
        HeaderValue::from_static("authorization,content-type,x-mjolnir-root"),
    );
    headers.insert("access-control-expose-headers", HeaderValue::from_static("location"));
    if allowed {
        if let Some(origin) = origin.and_then(|origin| HeaderValue::from_str(origin).ok()) {
            headers.insert("access-control-allow-origin", origin);
        }
        headers.insert("access-control-max-age", HeaderValue::from_static("600"));
    }
    response
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
    if raw.len() > PATH_BOUND || raw.contains('\\') || contains_forbidden_escape(raw) {
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
    lower.contains("%2f") || lower.contains("%5c") || lower.contains("%2e%2e") || lower.contains("%2e.")
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

async fn admit_http(State(edge): State<Arc<Edge>>, headers: HeaderMap, body: axum::body::Bytes) -> Response {
    let bearer = bearer(&headers);
    if bearer.is_none() {
        return err(AdmitError::NoToken);
    }
    let identity = match edge.admit_identity(
        bearer,
        headers.get("x-mjolnir-root").and_then(|value| value.to_str().ok()),
        None,
        SystemTime::now(),
    ) {
        Ok(identity) => identity,
        Err(error) => return err(error),
    };
    let parsed: AdmitBody = match serde_json::from_slice(&body) {
        Ok(parsed) => parsed,
        Err(_) => return err(AdmitError::BadRequest),
    };
    let operation = match parsed.operation.as_str() {
        "publish" => Op::Publish,
        "subscribe" => Op::Subscribe,
        _ => return err(AdmitError::BadRequest),
    };
    match edge.admit_broadcast(identity, operation, &parsed.broadcast, SystemTime::now()) {
        Ok(checked) => {
            let mut response = Json(json!({
                "root": checked.root,
                "exp": checked.exp_unix,
                "operation": parsed.operation,
                "broadcast": checked.broadcast,
            }))
            .into_response();
            response.headers_mut().insert("cache-control", HeaderValue::from_static("no-store"));
            response
        }
        Err(error) => err(error),
    }
}

async fn whip_http(State(edge): State<Arc<Edge>>, req: axum::extract::Request) -> Response {
    media_from_request(edge, Op::Publish, req).await
}

async fn whep_http(State(edge): State<Arc<Edge>>, req: axum::extract::Request) -> Response {
    media_from_request(edge, Op::Subscribe, req).await
}

async fn media_from_request(edge: Arc<Edge>, operation: Op, req: axum::extract::Request) -> Response {
    let path = req.uri().path().to_string();
    let headers = req.headers().clone();
    let extensions = req.extensions().clone();
    let body = http_body_util::BodyExt::collect(req.into_body())
        .await
        .map(|collected| collected.to_bytes())
        .unwrap_or_default();
    media_http(edge, operation, &path, headers, body, &extensions).await
}

async fn media_http(
    edge: Arc<Edge>,
    operation: Op,
    raw_path: &str,
    headers: HeaderMap,
    body: axum::body::Bytes,
    extensions: &axum::http::Extensions,
) -> Response {
    let Some(prefix) = (match operation {
        Op::Publish => raw_path.strip_prefix("/whip/"),
        Op::Subscribe => raw_path.strip_prefix("/whep/"),
    }) else {
        return err(AdmitError::BadRequest);
    };
    let Some((room, broadcast)) = prefix.split_once('/') else {
        return err(AdmitError::BadRequest);
    };
    if broadcast.is_empty() {
        return err(AdmitError::BadRequest);
    }
    let names: Vec<&str> = headers.keys().map(|key| key.as_str()).collect();
    tracing::debug!(%room, %broadcast, ?names, "media request");
    let identity = match edge.admit_identity(
        bearer(&headers),
        headers.get("x-mjolnir-root").and_then(|value| value.to_str().ok()),
        Some(room),
        SystemTime::now(),
    ) {
        Ok(identity) => identity,
        Err(error) => return err(error),
    };
    let checked = match edge.admit_broadcast(identity, operation, broadcast, SystemTime::now()) {
        Ok(checked) => checked,
        Err(error) => return err(error),
    };
    let offer = String::from_utf8_lossy(&body).into_owned();
    match edge.open_session(&checked, &offer).await {
        Ok(negotiated) => queue_http(edge, negotiated, extensions),
        Err(error) => err(error),
    }
}

async fn delete_http(State(edge): State<Arc<Edge>>, Path(id): Path<String>, headers: HeaderMap) -> Response {
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
    (
        status,
        [(axum::http::header::CONTENT_TYPE, "application/json")],
        Json(json!({"error": code})),
    )
        .into_response()
}

pub fn error_body(error: AdmitError) -> (StatusCode, Value) {
    let (status, code) = error.status();
    (status, json!({"error": code}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use http_body_util::BodyExt;
    use moq_auth::{Algorithm, Claims, Key};
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use tower::ServiceExt;

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
        let _ = (key, now);
        (set, token)
    }

    fn mint_shaped_open() -> (KeySet, String, String) {
        let owner = owner();
        let root = format!("t/{owner}/~open/standup");
        let (set, token) = sign("alice/**", "**", &root, Duration::from_secs(600));
        (set, token, root)
    }

    fn checked(edge: &Edge, token: &str, root: &str, op: Op) -> Checked {
        edge.admit(Some(token), Some(root), Some("standup"), op, "alice/cam", SystemTime::now()).unwrap()
    }

    async fn http(edge: &Arc<Edge>, token: &str, root: &str, method: &str, path: &str, body: &str) -> Response {
        let req = axum::http::Request::builder()
            .method(method)
            .uri(path)
            .header("authorization", format!("Bearer {token}"))
            .header("x-mjolnir-root", root)
            .header("content-type", "application/sdp")
            .header("origin", "https://unlisted.invalid")
            .header("host", "edge.test")
            .body(Body::from(body.to_owned()))
            .unwrap();
        edge.router().oneshot(req).await.unwrap()
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
        let ok = edge.admit(Some(&token), Some(&root), None, Op::Publish, "alice/cam", SystemTime::now()).unwrap();
        assert_eq!(ok.broadcast, "alice/cam");
        assert!(ok.exp > SystemTime::now());
        assert_eq!(edge.dials(), 0);
        let protected = format!("t/{}/standup", owner());
        let (set, token) = sign("alice/**", "**", &protected, Duration::from_secs(600));
        let edge = Edge::new(set);
        assert_eq!(
            edge.admit(Some(&token), Some("ignored"), None, Op::Publish, "alice/cam", SystemTime::now()).unwrap_err(),
            AdmitError::RoomNotOpen
        );
        let wide = format!("t/{}", owner());
        let (set, token) = sign("**", "**", &wide, Duration::from_secs(60));
        let edge = Edge::new(set);
        assert_eq!(
            edge.admit(Some(&token), Some(&wide), None, Op::Publish, "alice/cam", SystemTime::now()).unwrap_err(),
            AdmitError::RoomNotOpen
        );
    }

    #[test]
    fn foreign_broadcast_header_mismatch_and_closed_admissions_do_not_dial() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        assert_eq!(
            edge.admit(Some(&token), Some(&root), None, Op::Publish, "bob/cam", SystemTime::now()).unwrap_err(),
            AdmitError::Forbidden
        );
        assert_eq!(
            edge.admit(Some(&token), Some("other"), None, Op::Publish, "alice/cam", SystemTime::now()).unwrap_err(),
            AdmitError::UnexpectedRoot
        );
        assert_eq!(
            edge.admit(None, Some(&root), None, Op::Publish, "alice/cam", SystemTime::now()).unwrap_err(),
            AdmitError::NoToken
        );
        edge.close_admissions();
        assert_eq!(
            edge.admit(Some(&token), Some(&root), None, Op::Publish, "alice/cam", SystemTime::now()).unwrap_err(),
            AdmitError::BadToken
        );
        assert_eq!(edge.dials(), 0);
    }

    #[tokio::test]
    async fn two_legs_one_token_one_dial_and_delete_matrix() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        edge.enable_test_dial();
        let a = checked(&edge, &token, &root, Op::Publish);
        let b = checked(&edge, &token, &root, Op::Subscribe);
        let id_a = edge.attach(&a, "m=video 9 UDP/TLS/RTP/SAVPF 96\n", "m=video 9 UDP/TLS/RTP/SAVPF 96\n", SystemTime::now()).await.unwrap();
        let id_b = edge.attach(&b, "m=audio 9 UDP/TLS/RTP/SAVPF 111\n", "m=audio 9 UDP/TLS/RTP/SAVPF 111\n", SystemTime::now()).await.unwrap();
        assert_eq!(edge.dials(), 1);
        assert_eq!(edge.refs(&token), 2);
        let (_set2, other, _root2) = mint_shaped_open();
        assert_eq!(edge.delete(&id_a, Some(&other), SystemTime::now()).unwrap_err(), AdmitError::Forbidden);
        assert_eq!(edge.refs(&token), 2);
        edge.delete(&id_a, Some(&token), SystemTime::now()).unwrap();
        edge.delete(&id_a, Some(&token), SystemTime::now()).unwrap();
        assert_eq!(edge.delete(&id_a, Some(&other), SystemTime::now()).unwrap_err(), AdmitError::Forbidden);
        assert_eq!(edge.delete("missing", Some(&token), SystemTime::now()).unwrap_err(), AdmitError::NotFound);
        edge.delete(&id_b, Some(&token), SystemTime::now()).unwrap();
        assert_eq!(edge.refs(&token), 0);
        assert_eq!(edge.link_count(), 0);
        assert_eq!(
            edge.attach(&a, "m=video 9 UDP/TLS/RTP/SAVPF 96\n", "m=video 0 UDP/TLS/RTP/SAVPF 96\n", SystemTime::now()).await.unwrap_err(),
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
        assert!(!edge.admissions_open());
        assert_eq!(
            edge.admit(Some(&token), Some(&root), None, Op::Publish, "alice/cam", SystemTime::now()).unwrap_err(),
            AdmitError::BadToken
        );
    }

    #[tokio::test]
    async fn concurrent_posts_share_one_dial_and_a_later_acquire_dials_again() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        edge.enable_test_dial();
        *edge.test_dial_wait.lock().unwrap() = Duration::from_millis(80);
        let a = checked(&edge, &token, &root, Op::Publish);
        let b = checked(&edge, &token, &root, Op::Subscribe);
        let offer = "m=audio 9 UDP/TLS/RTP/SAVPF 111\n";
        let (left, right) = tokio::join!(edge.attach(&a, offer, offer, SystemTime::now()), edge.attach(&b, offer, offer, SystemTime::now()));
        assert!(left.is_ok() && right.is_ok());
        assert_eq!(edge.dials(), 1);
        assert_eq!(edge.refs(&token), 2);
        edge.delete(&left.unwrap(), Some(&token), SystemTime::now()).unwrap();
        edge.delete(&right.unwrap(), Some(&token), SystemTime::now()).unwrap();
        assert_eq!(edge.refs(&token), 0);
        let again = checked(&edge, &token, &root, Op::Publish);
        edge.attach(&again, offer, offer, SystemTime::now()).await.unwrap();
        assert_eq!(edge.dials(), 2);
    }

    #[tokio::test]
    async fn rejected_leader_keeps_waiter_reservation() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        edge.enable_test_dial();
        let a = checked(&edge, &token, &root, Op::Publish);
        let b = checked(&edge, &token, &root, Op::Subscribe);
        let (left, right) = tokio::join!(
            edge.attach(&a, "m=video 9 RTP/AVP 96", "m=video 0 RTP/AVP 96", SystemTime::now()),
            edge.attach(&b, "m=audio 9 RTP/AVP 111", "m=audio 9 RTP/AVP 111", SystemTime::now()),
        );
        assert_eq!(left.unwrap_err(), AdmitError::CodecUnavailable);
        assert!(right.is_ok());
        assert_eq!(edge.refs(&token), 1);
        assert_eq!(edge.link_count(), 1);
    }

    #[tokio::test]
    async fn cancelled_waiter_does_not_stick_a_ref() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        edge.enable_test_dial();
        *edge.test_dial_wait.lock().unwrap() = Duration::from_millis(200);
        let a = checked(&edge, &token, &root, Op::Publish);
        let b = checked(&edge, &token, &root, Op::Subscribe);
        let offer = "m=audio 9 RTP/AVP 111";
        let leader = {
            let edge = Arc::clone(&edge);
            let a = a.clone();
            tokio::spawn(async move { edge.attach(&a, offer, offer, SystemTime::now()).await })
        };
        tokio::time::timeout(Duration::from_secs(1), async {
            while edge.dials() == 0 {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        let edge_w = Arc::clone(&edge);
        let waiter = tokio::spawn(async move { edge_w.attach(&b, offer, offer, SystemTime::now()).await });
        tokio::time::sleep(Duration::from_millis(20)).await;
        waiter.abort();
        let _ = waiter.await;
        let id = tokio::time::timeout(Duration::from_secs(2), leader).await.unwrap().unwrap().unwrap_or_else(|err| {
            panic!("leader {err:?} dials={} refs={} flights={}", edge.dials(), edge.refs(&token), edge.flight_count());
        });
        assert_eq!(edge.refs(&token), 1);
        edge.delete(&id, Some(&token), SystemTime::now()).unwrap();
        assert_eq!(edge.refs(&token), 0);
        assert_eq!(edge.link_count(), 0);
    }

    #[tokio::test]
    async fn first_acquire_past_exp_is_bad_token() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        edge.enable_test_dial();
        let mut c = checked(&edge, &token, &root, Op::Publish);
        c.exp = SystemTime::now() - Duration::from_secs(1);
        let error = edge.attach(&c, "m=audio 9 RTP/AVP 111", "m=audio 9 RTP/AVP 111", SystemTime::now()).await.unwrap_err();
        assert_eq!(error, AdmitError::BadToken);
        assert_eq!(edge.dials(), 0);
    }

    #[tokio::test]
    async fn candidate_timeout_keeps_the_other_token() {
        let key = Key::generate(Algorithm::EdDSA, None).unwrap();
        let owner_a = bs58::encode([9u8; 32]).into_string();
        let root = format!("t/{owner_a}/~open/standup");
        let owner_b = bs58::encode([8u8; 32]).into_string();
        let root2 = format!("t/{owner_b}/~open/standup");
        let now = kio::clock::wall();
        let token = key
            .sign(
                &Claims::default()
                    .with_root(&root)
                    .with_publish(["alice/**".parse().unwrap()])
                    .with_subscribe(["**".parse().unwrap()])
                    .with_issued(now)
                    .with_expires(now + Duration::from_secs(600)),
            )
            .unwrap();
        let other = key
            .sign(
                &Claims::default()
                    .with_root(&root2)
                    .with_publish(["alice/**".parse().unwrap()])
                    .with_subscribe(["**".parse().unwrap()])
                    .with_issued(now)
                    .with_expires(now + Duration::from_secs(600)),
            )
            .unwrap();
        let edge = Edge::new(KeySet { keys: vec![std::sync::Arc::new(key.public().unwrap())] });
        edge.enable_test_dial();
        let incumbent_checked = checked(&edge, &token, &root, Op::Publish);
        let offer = "m=audio 9 RTP/AVP 111";
        let incumbent = edge.attach(&incumbent_checked, offer, offer, SystemTime::now()).await.unwrap();
        let mut slow = edge
            .admit(Some(&other), Some(&root2), Some("standup"), Op::Publish, "alice/cam", SystemTime::now())
            .unwrap();
        slow.exp = SystemTime::now() + Duration::from_millis(40);
        *edge.test_dial_wait.lock().unwrap() = Duration::from_secs(2);
        assert_ne!(token, other);
        let started = std::time::Instant::now();
        let error = edge.attach(&slow, offer, offer, SystemTime::now()).await.unwrap_err();
        assert_eq!(error, AdmitError::BadToken);
        assert!(started.elapsed() < Duration::from_millis(800));
        assert_eq!(edge.refs(&token), 1);
        assert!(edge.delete(&incumbent, Some(&token), SystemTime::now()).is_ok());
        assert_eq!(edge.link_count(), 0);
    }

    #[tokio::test]
    async fn tombstone_horizon_reaps_without_another_delete() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        edge.enable_test_dial();
        let c = checked(&edge, &token, &root, Op::Publish);
        let offer = "m=audio 9 RTP/AVP 111";
        let id = edge.attach(&c, offer, offer, SystemTime::now()).await.unwrap();
        edge.sweep(c.exp + Duration::from_secs(1));
        assert_eq!(edge.session_count(), 0);
        assert_eq!(edge.refs(&token), 0);
        assert_eq!(edge.delete(&id, Some(&token), c.exp + Duration::from_secs(1)).unwrap(), ());
        let (_s, other, _) = mint_shaped_open();
        assert_eq!(edge.delete(&id, Some(&other), c.exp + Duration::from_secs(1)).unwrap_err(), AdmitError::Forbidden);
        assert_eq!(edge.tombstone_count(), 1);
        edge.sweep(c.exp + Duration::from_secs(31));
        assert_eq!(edge.tombstone_count(), 0);
        assert_eq!(edge.delete(&id, Some(&token), c.exp + Duration::from_secs(31)).unwrap_err(), AdmitError::NotFound);
    }

    #[tokio::test]
    async fn http_single_decode_and_admit_envelope() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        edge.enable_test_dial();
        let missing = http(&edge, &token, &root, "POST", "/admit", "{}").await;
        assert_eq!(missing.status(), 400);
        let bytes = missing.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(bytes, r#"{"error":"bad_request"}"#);
        let no_token = axum::http::Request::builder()
            .method("POST")
            .uri("/admit")
            .header("content-type", "application/json")
            .body(Body::from("{"))
            .unwrap();
        let denied = edge.router().oneshot(no_token).await.unwrap();
        assert_eq!(denied.status(), 401);
        let ok = http(&edge, &token, &root, "POST", "/admit", r#"{"operation":"publish","broadcast":"alice/cam"}"#).await;
        assert_eq!(ok.status(), 200);
        assert_eq!(ok.headers()["cache-control"], "no-store");
        assert!(ok.headers().get("access-control-allow-origin").is_none());
        let preflight = axum::http::Request::builder()
            .method("OPTIONS")
            .uri("/admit")
            .header("origin", "http://edge.test")
            .header("host", "edge.test")
            .body(Body::empty())
            .unwrap();
        let preflight = edge.router().oneshot(preflight).await.unwrap();
        assert_eq!(preflight.headers()["access-control-allow-origin"], "http://edge.test");
        assert_eq!(preflight.headers()["access-control-max-age"], "600");
        assert_eq!(preflight.headers()["vary"], "origin");
        for path in ["/whip/standup/alice%2fcam", "/whip/standup/%2561lice/cam", "/whep/standup/alice%5ccam"] {
            let response = http(&edge, &token, &root, "POST", path, "v=0").await;
            assert_eq!(response.status(), 400, "{path}");
        }
        assert_eq!(edge.dials(), 0);
        // oneshot + collect is not delivery. Without a DeliveryContext the candidate is refused.
        let compared = http(&edge, &token, &root, "POST", "/whip/standup/alice/cam%2D1", "m=audio 9 RTP/AVP 111").await;
        assert_eq!(compared.status(), 503);
        assert_eq!(edge.session_count(), 0);
        assert_eq!(edge.runner_count(), 0);
        let delivered = deliver(&edge, &token, &root, "/whip/standup/alice/cam%2D1", "m=audio 9 RTP/AVP 111", WireMode::Ok).await;
        assert!(delivered.contains("201 Created"), "{delivered}");
        assert_eq!(edge.moq_paths(), vec!["alice/cam-1".to_string(), "alice/cam-1".to_string()]);
        assert_eq!(edge.session_count(), 1);
        assert_eq!(edge.runner_count(), 0);
    }

    #[tokio::test]
    async fn drain_is_not_cleared_by_a_good_reload() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set.clone());
        edge.drain();
        assert!(!edge.admissions_open());
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("keys.json");
        std::fs::write(&path, "{\"keys\":[]}").unwrap();
        let _ = edge.reload_keys(&path);
        assert!(!edge.admissions_open());
        edge.snap.lock().unwrap().draining = false;
        edge.snap.lock().unwrap().keys_ok = true;
        edge.snap.lock().unwrap().keys = set;
        assert!(edge.admit(Some(&token), Some(&root), None, Op::Publish, "alice/cam", SystemTime::now()).is_ok());
    }

    #[test]
    fn configured_origins_are_an_exact_list() {
        let (set, _, _) = mint_shaped_open();
        let edge = Edge::new(set);
        edge.set_origins(vec!["https://named-peer.test".into()]);
        assert!(origin_allowed(&edge, "https://named-peer.test", "edge.test"));
        assert!(!origin_allowed(&edge, "http://edge.test", "edge.test"));
        assert!(!origin_allowed(&edge, "https://edge.test", "edge.test"));
        edge.set_origins(Vec::new());
        assert!(origin_allowed(&edge, "http://edge.test", "edge.test"));
        assert!(!origin_allowed(&edge, "https://edge.test", "edge.test"));
        assert!(!origin_allowed(&edge, "http://other.test", "edge.test"));
    }

    #[tokio::test]
    async fn drain_during_dial_does_not_register() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        edge.enable_test_dial();
        *edge.test_dial_wait.lock().expect("wait") = Duration::from_millis(400);
        let checked = edge.admit(Some(&token), Some(&root), None, Op::Publish, "alice/cam", SystemTime::now()).unwrap();
        let worker = edge.clone();
        let task = tokio::spawn(async move { worker.open_session(&checked, "v=0").await });
        tokio::time::timeout(Duration::from_secs(2), async {
            while edge.dials() == 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("dial started");
        edge.drain();
        let result = tokio::time::timeout(Duration::from_secs(2), task).await.expect("dial finished").unwrap();
        assert!(matches!(result, Err(AdmitError::SetupFailed)));
        assert_eq!((edge.session_count(), edge.link_count(), edge.flight_count()), (0, 0, 0));
    }

    #[tokio::test]
    async fn stale_generation_cleanup_leaves_the_replacement() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        edge.enable_test_dial();
        let checked = edge.admit(Some(&token), Some(&root), None, Op::Publish, "alice/cam", SystemTime::now()).unwrap();
        let deadline = setup_deadline(checked.exp).unwrap();
        let first = edge.acquire(&checked.token, checked.exp, &deadline).await.unwrap();
        let old = first.generation;
        drop(first);
        assert_eq!(edge.link_count(), 0);
        let second = edge.acquire(&checked.token, checked.exp, &deadline).await.unwrap();
        let replacement = second.generation;
        assert_ne!(old, replacement);
        edge.drop_token_gen(&checked.token, old);
        assert_eq!(edge.refs(&checked.token), 1);
        assert_eq!(edge.link_count(), 1);
        edge.drop_token_gen(&checked.token, replacement);
        assert_eq!((edge.refs(&checked.token), edge.link_count()), (0, 0));
        drop(second);
    }

    #[tokio::test]
    async fn last_release_closes_the_real_relay_connection() {
        use std::sync::atomic::AtomicBool;
        use std::sync::Mutex;

        let _ = moq_tokio::crypto::install_default();
        let dir = tempfile::tempdir().unwrap();
        let key = rcgen::KeyPair::generate().unwrap();
        let cert = rcgen::CertificateParams::new(vec!["localhost".into()]).unwrap().self_signed(&key).unwrap();
        let cert_path = dir.path().join("cert.pem");
        let key_path = dir.path().join("key.pem");
        std::fs::write(&cert_path, cert.pem()).unwrap();
        std::fs::write(&key_path, key.serialize_pem()).unwrap();
        let mut cfg = moq_relay::Config::default();
        cfg.listen.bind = Some("127.0.0.1:0".parse().unwrap());
        cfg.listen.tls.cert = vec![cert_path.clone()];
        cfg.listen.tls.key = vec![key_path];
        cfg.web.ws = false;
        let mut relay = moq_relay::Relay::load(cfg).await.unwrap().with_signals(false);
        let addr = relay.quic_addr().unwrap();
        let admissions = relay.admissions().unwrap();
        let ready = relay.ready();
        let relay_task = tokio::spawn(async move { relay.run().await });
        ready.wait().await.unwrap();

        let (set, token, root) = mint_shaped_open();
        crate::spawn_web_decider(
            admissions,
            Arc::new(Mutex::new(set.clone())),
            Arc::new(AtomicBool::new(false)),
            Arc::new(AtomicBool::new(true)),
            crate::DEFAULT_MAX_TTL,
        );
        let edge = Edge::new(set);
        edge.set_moq(crate::moq_session::MoqConfig {
            relay: format!("https://localhost:{}", addr.port()).parse().unwrap(),
            tls_root: Some(cert_path),
            media: moq_webrtc::Server::bind("127.0.0.1:0".parse().unwrap(), Default::default()).await.unwrap(),
        });
        let checked = edge.admit(Some(&token), Some(&root), None, Op::Publish, "alice/cam", SystemTime::now()).unwrap();
        let deadline = setup_deadline(checked.exp).unwrap();
        let reservation = edge.acquire(&checked.token, checked.exp, &deadline).await.unwrap();
        let weak = std::sync::Arc::downgrade(edge.pool.lock().expect("pool").links[&checked.token].shared.as_ref().unwrap());
        assert!(weak.upgrade().is_some_and(|shared| !shared.dead()));
        drop(reservation);
        assert_eq!(edge.link_count(), 0);
        tokio::time::timeout(Duration::from_secs(2), async {
            while weak.upgrade().is_some_and(|shared| !shared.dead()) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("released connection stays connected");
        let next = edge.acquire(&checked.token, checked.exp, &deadline).await.unwrap();
        assert_eq!(edge.dials(), 2);
        assert!(weak.upgrade().is_none_or(|shared| shared.dead()));
        let current = edge.pool.lock().expect("pool").links[&checked.token].shared.as_ref().unwrap().clone();
        assert!(!current.dead());
        drop(next);
        assert_eq!(edge.link_count(), 0);
        tokio::time::timeout(Duration::from_secs(2), async {
            while !current.dead() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("second connection stays connected after release");
        edge.drain();
        relay_task.abort();
    }

    #[test]
    fn ttl_ceiling_is_the_snapshot_value() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        assert!(edge.set_max_ttl(Duration::ZERO).is_err());
        edge.set_max_ttl(Duration::from_secs(30)).unwrap();
        assert_eq!(
            edge.admit(Some(&token), Some(&root), None, Op::Publish, "alice/cam", SystemTime::now()).unwrap_err(),
            AdmitError::BadToken
        );
        edge.set_max_ttl(Duration::from_secs(3600)).unwrap();
        assert!(edge.admit(Some(&token), Some(&root), None, Op::Publish, "alice/cam", SystemTime::now()).is_ok());
    }

    #[derive(Clone, Copy, PartialEq)]
    enum WireMode {
        Ok,
        WriteFail,
        PartialFail,
        FlushFail,
        Stall,
        Zero,
        /// First response flushes; the next flush fails.
        SecondFlushFails,
        /// Hold flushes until `release` is set.
        HoldFlush,
    }

    fn whip_bytes(token: &str, root: &str, path: &str, body: &str) -> Vec<u8> {
        format!(
            "POST {path} HTTP/1.1\r\nHost: edge.test\r\nAuthorization: Bearer {token}\r\nx-mjolnir-root: {root}\r\nContent-Type: application/sdp\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        )
        .into_bytes()
    }

    async fn deliver(edge: &Arc<Edge>, token: &str, root: &str, path: &str, body: &str, mode: WireMode) -> String {
        let captured = Arc::new(Mutex::new(Vec::<u8>::new()));
        let release = Arc::new(AtomicBool::new(mode != WireMode::HoldFlush));
        let waker = Arc::new(Mutex::new(None));
        let flushed = Arc::new(AtomicU64::new(0));
        let io = Captured {
            request: Mutex::new(Some(whip_bytes(token, root, path, body))),
            mode,
            max_write: 17,
            partial: AtomicBool::new(false),
            flushes: AtomicU64::new(0),
            bytes: Arc::clone(&captured),
            release: Arc::clone(&release),
            waker: Arc::clone(&waker),
            flushed: Arc::clone(&flushed),
        };
        let router = edge.router();
        let task = tokio::spawn(crate::edge_http::serve_connection(io, router));
        let wait = if matches!(mode, WireMode::Stall) { Duration::from_millis(200) } else { Duration::from_secs(2) };
        let _ = tokio::time::timeout(wait, async {
            loop {
                if task.is_finished() {
                    break;
                }
                let text = String::from_utf8_lossy(&captured.lock().expect("cap")).into_owned();
                let flushed_ok = flushed.load(Ordering::SeqCst) > 0;
                if matches!(mode, WireMode::Ok | WireMode::SecondFlushFails) && text.contains("201 Created") && flushed_ok {
                    break;
                }
                if matches!(mode, WireMode::WriteFail | WireMode::PartialFail | WireMode::FlushFail | WireMode::Zero) && task.is_finished() {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await;
        if !task.is_finished() {
            task.abort();
        }
        let _ = task.await;
        let text = String::from_utf8_lossy(&captured.lock().expect("cap")).into_owned();
        text
    }

    struct Captured {
        request: Mutex<Option<Vec<u8>>>,
        mode: WireMode,
        max_write: usize,
        partial: AtomicBool,
        flushes: AtomicU64,
        bytes: Arc<Mutex<Vec<u8>>>,
        release: Arc<AtomicBool>,
        waker: Arc<Mutex<Option<std::task::Waker>>>,
        flushed: Arc<AtomicU64>,
    }

    impl tokio::io::AsyncRead for Captured {
        fn poll_read(
            self: std::pin::Pin<&mut Self>,
            _cx: &mut std::task::Context<'_>,
            buf: &mut tokio::io::ReadBuf<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            let me = self.get_mut();
            if let Some(req) = me.request.lock().expect("req").take() {
                buf.put_slice(&req);
                std::task::Poll::Ready(Ok(()))
            } else {
                std::task::Poll::Pending
            }
        }
    }

    impl tokio::io::AsyncWrite for Captured {
        fn poll_write(
            self: std::pin::Pin<&mut Self>,
            _cx: &mut std::task::Context<'_>,
            buf: &[u8],
        ) -> std::task::Poll<std::io::Result<usize>> {
            let me = self.get_mut();
            match me.mode {
                WireMode::WriteFail => return std::task::Poll::Ready(Err(std::io::ErrorKind::BrokenPipe.into())),
                WireMode::PartialFail if me.partial.load(Ordering::SeqCst) => {
                    return std::task::Poll::Ready(Err(std::io::ErrorKind::BrokenPipe.into()));
                }
                WireMode::Zero => return std::task::Poll::Ready(Ok(0)),
                _ => {}
            }
            let n = buf.len().min(me.max_write);
            me.partial.store(true, Ordering::SeqCst);
            me.bytes.lock().expect("bytes").extend_from_slice(&buf[..n]);
            std::task::Poll::Ready(Ok(n))
        }

        fn poll_flush(self: std::pin::Pin<&mut Self>, cx: &mut std::task::Context<'_>) -> std::task::Poll<std::io::Result<()>> {
            let me = self.get_mut();
            let n = me.flushes.fetch_add(1, Ordering::SeqCst);
            match me.mode {
                WireMode::FlushFail => return std::task::Poll::Ready(Err(std::io::ErrorKind::BrokenPipe.into())),
                WireMode::SecondFlushFails
                    if me.bytes.lock().expect("bytes").windows(11).filter(|w| *w == b"201 Created").count() >= 2 =>
                {
                    return std::task::Poll::Ready(Err(std::io::ErrorKind::BrokenPipe.into()));
                }
                WireMode::Stall => return std::task::Poll::Pending,
                WireMode::HoldFlush if !me.release.load(Ordering::SeqCst) => {
                    *me.waker.lock().expect("waker") = Some(cx.waker().clone());
                    return std::task::Poll::Pending;
                }
                _ => {}
            }
            me.flushed.fetch_add(1, Ordering::SeqCst);
            std::task::Poll::Ready(Ok(()))
        }

        fn poll_shutdown(self: std::pin::Pin<&mut Self>, _cx: &mut std::task::Context<'_>) -> std::task::Poll<std::io::Result<()>> {
            std::task::Poll::Ready(Ok(()))
        }
    }

    #[tokio::test]
    async fn http_flush_ack_keeps_session_after_close_and_failures_do_not() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        edge.enable_test_dial();
        let offer = "m=audio 9 RTP/AVP 111";
        let incumbent = {
            let checked = checked(&edge, &token, &root, Op::Publish);
            edge.attach(&checked, offer, offer, SystemTime::now()).await.unwrap()
        };
        assert_eq!((edge.session_count(), edge.runner_count(), edge.refs(&token)), (1, 0, 1));

        let ok = deliver(&edge, &token, &root, "/whip/standup/alice/cam", offer, WireMode::Ok).await;
        assert!(ok.contains("201 Created"), "{ok}");
        assert!(ok.contains("v=0"), "{ok}");
        assert_eq!((edge.session_count(), edge.runner_count()), (2, 0));

        let broken = deliver(&edge, &token, &root, "/whip/standup/alice/cam", offer, WireMode::WriteFail).await;
        assert!(!broken.contains("201 Created"), "{broken}");
        assert_eq!((edge.session_count(), edge.runner_count(), edge.refs(&token)), (2, 0, 2));

        let partial = deliver(&edge, &token, &root, "/whip/standup/alice/cam", offer, WireMode::PartialFail).await;
        assert_eq!(edge.session_count(), 2, "partial write then BrokenPipe left {partial}");
        let flush = deliver(&edge, &token, &root, "/whip/standup/alice/cam", offer, WireMode::FlushFail).await;
        assert_eq!(edge.session_count(), 2, "{flush}");
        let zero = deliver(&edge, &token, &root, "/whip/standup/alice/cam", offer, WireMode::Zero).await;
        assert_eq!(edge.session_count(), 2, "{zero}");
        let stall = deliver(&edge, &token, &root, "/whip/standup/alice/cam", offer, WireMode::Stall).await;
        assert_eq!(edge.session_count(), 2, "stall dropped the connection: {stall}");
        assert_eq!(edge.runner_count(), 0);
        assert!(edge.delete(&incumbent, Some(&token), SystemTime::now()).is_ok());
    }

    #[tokio::test]
    async fn pipelined_second_response_failure_keeps_the_first_ack() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        edge.enable_test_dial();
        let body = "m=audio 9 RTP/AVP 111";
        let first = whip_bytes(&token, &root, "/whip/standup/alice/cam", body);
        let second = whip_bytes(&token, &root, "/whip/standup/alice/cam", body);
        let mut both = first;
        both.extend_from_slice(&second);
        let captured = Arc::new(Mutex::new(Vec::<u8>::new()));
        let io = Captured {
            request: Mutex::new(Some(both)),
            mode: WireMode::SecondFlushFails,
            max_write: 17,
            partial: AtomicBool::new(false),
            flushes: AtomicU64::new(0),
            bytes: Arc::clone(&captured),
            release: Arc::new(AtomicBool::new(true)),
            waker: Arc::new(Mutex::new(None)),
            flushed: Arc::new(AtomicU64::new(0)),
        };
        let task = tokio::spawn(crate::edge_http::serve_connection(io, edge.router()));
        let _ = tokio::time::timeout(Duration::from_secs(2), async {
            while !task.is_finished() {
                tokio::task::yield_now().await;
            }
        })
        .await;
        if !task.is_finished() {
            task.abort();
        }
        let _ = task.await;
        let text = String::from_utf8_lossy(&captured.lock().expect("cap")).into_owned();
        assert!(text.contains("201 Created"), "{text}");
        assert_eq!(edge.session_count(), 1, "{text}");
        assert_eq!(edge.runner_count(), 0);
    }

    #[tokio::test]
    async fn stale_deadline_drain_and_generation_do_not_start_at_ack() {
        let (set, token, root) = mint_shaped_open();
        let edge = Edge::new(set);
        edge.enable_test_dial();
        let body = "m=audio 9 RTP/AVP 111";
        let release = Arc::new(AtomicBool::new(false));
        let waker = Arc::new(Mutex::new(None));
        let captured = Arc::new(Mutex::new(Vec::<u8>::new()));
        let io = Captured {
            request: Mutex::new(Some(whip_bytes(&token, &root, "/whip/standup/alice/cam", body))),
            mode: WireMode::HoldFlush,
            max_write: 17,
            partial: AtomicBool::new(false),
            flushes: AtomicU64::new(0),
            bytes: Arc::clone(&captured),
            release: Arc::clone(&release),
            waker: Arc::clone(&waker),
            flushed: Arc::new(AtomicU64::new(0)),
        };
        let task = tokio::spawn(crate::edge_http::serve_connection(io, edge.router()));
        tokio::time::timeout(Duration::from_secs(2), async {
            while edge.session_count() == 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("candidate parked");
        assert_eq!(edge.runner_count(), 0);
        {
            let mut pool = edge.pool.lock().expect("pool");
            let session = pool.sessions.values_mut().find(|session| matches!(session.leg, Leg::Pending { .. })).expect("pending");
            if let Leg::Pending { deadline, .. } = &mut session.leg {
                *deadline = SystemTime::UNIX_EPOCH;
            }
        }
        release.store(true, Ordering::SeqCst);
        if let Some(waker) = waker.lock().expect("waker").take() {
            waker.wake();
        }
        let _ = tokio::time::timeout(Duration::from_secs(2), async {
            while !task.is_finished() {
                tokio::task::yield_now().await;
            }
        })
        .await;
        if !task.is_finished() {
            task.abort();
        }
        let _ = task.await;
        assert_eq!(edge.session_count(), 0);
        assert_eq!(edge.runner_count(), 0);
    }
}
