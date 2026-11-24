//! Shared harness: a real moq-relay with the Mjolnir WebTransport decider, and tokens
//! shaped exactly as `Mjolnir.Relay.Mint` signs them (root `t/<owner>/<room>`,
//! publish `[<participant>/**]`, subscribe `[**]`).
#![allow(dead_code)]
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use moq_auth::{Algorithm, Claims, Key, KeySet};
use moq_relay::{Config, Relay};

pub struct Running {
    pub quic: std::net::SocketAddr,
    pub trigger: moq_relay::shutdown::Trigger,
    pub join: tokio::task::JoinHandle<anyhow::Result<()>>,
    pub key: Key,
    _dir: tempfile::TempDir,
}

fn cert_pair(dir: &Path) -> (PathBuf, PathBuf) {
    let key = rcgen::KeyPair::generate().unwrap();
    let params = rcgen::CertificateParams::new(vec!["localhost".into()]).unwrap();
    let cert = params.self_signed(&key).unwrap();
    let cert_path = dir.join("cert.pem");
    let key_path = dir.join("key.pem");
    std::fs::write(&cert_path, cert.pem()).unwrap();
    std::fs::write(&key_path, key.serialize_pem()).unwrap();
    (cert_path, key_path)
}

pub fn lite07() -> bool {
    std::env::var("SPIKE_LITE07").as_deref() == Ok("1")
}

fn versions() -> Vec<moq_net::Version> {
    let mut v: Vec<moq_net::Version> = moq_net::Versions::all().iter().copied().collect();
    v.insert(0, "moq-lite-07-wip".parse().unwrap());
    v
}

pub async fn start() -> Running {
    let dir = tempfile::tempdir().unwrap();
    let (cert, tls_key) = cert_pair(dir.path());
    let _ = moq_tokio::crypto::install_default();
    let mut config = Config::default();
    config.listen.bind = Some("127.0.0.1:0".parse().unwrap());
    config.listen.tls.cert = vec![cert];
    config.listen.tls.key = vec![tls_key];
    config.web.ws = false;
    if lite07() {
        config.listen.version = versions();
    }
    let mut relay = Relay::load(config).await.unwrap().with_signals(false);
    let quic = relay.quic_addr().unwrap();
    let trigger = relay.shutdown_trigger().clone();
    let admissions = relay.admissions().unwrap();
    let ready = relay.ready();
    let join = tokio::spawn(relay.run());
    ready.wait().await.unwrap();
    let key = Key::generate(Algorithm::EdDSA, None).unwrap();
    let keys = Arc::new(Mutex::new(KeySet {
        keys: vec![Arc::new(key.public().unwrap())],
    }));
    mjolnir_relay::spawn_web_decider(
        admissions,
        keys,
        Arc::new(AtomicBool::new(false)),
        Arc::new(AtomicBool::new(true)),
        Duration::from_secs(3600),
    );
    Running {
        quic,
        trigger,
        join,
        key,
        _dir: dir,
    }
}

pub fn owner() -> String {
    bs58::encode([9u8; 32]).into_string()
}

/// The claims `Mjolnir.Relay.Mint.sign/7` puts in a room token.
pub fn room_token(key: &Key, room: &str, participant: &str, seconds: u64) -> String {
    let now = kio::clock::wall();
    let claims = Claims::default()
        .with_root(format!("t/{}/{room}", owner()))
        .with_publish([format!("{participant}/**").parse().unwrap()])
        .with_subscribe(["**".parse().unwrap()])
        .with_issued(now)
        .with_expires(now + Duration::from_secs(seconds));
    key.sign(&claims).unwrap()
}

pub fn url(running: &Running, token: &str) -> url::Url {
    format!("https://{}/?jwt={token}", running.quic).parse().unwrap()
}

pub fn client() -> moq_tokio::Client {
    let mut config = moq_tokio::connect::Config::default();
    config.tls.insecure = Some(true);
    config.bind = Some("127.0.0.1:0".parse().unwrap());
    if lite07() {
        config.version = versions();
    }
    config.init(Default::default()).unwrap().with_reconnect(false)
}

pub fn timed() -> moq_net::track::Info {
    moq_net::track::Info::default().with_timescale(moq_net::Timescale::MILLI)
}

pub fn now() -> moq_net::Timestamp {
    moq_net::Timestamp::from(moq_net::time::Instant::now())
}

pub fn credential(secret: [u8; 32], kid: u64) -> moq_e2ee::Credential {
    moq_e2ee::Credential::new(moq_e2ee::credential::Config {
        // The room identity both ends agree on. Not the relay path, which a relay may remount.
        context: format!("mjolnir-call/v1/{}/r1", owner()).into(),
        kid,
        secret,
    })
    .unwrap()
}

pub fn contains(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}
