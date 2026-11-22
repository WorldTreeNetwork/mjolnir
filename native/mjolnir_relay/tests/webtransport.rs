//! WebTransport refusal and drain. Throwaway certificates, loopback only.
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use moq_auth::{Algorithm, Claims, Key, KeySet};
use moq_relay::{Config, Relay};

fn cert_pair(dir: &Path, name: &str) -> (PathBuf, PathBuf) {
    let key = rcgen::KeyPair::generate().unwrap();
    let params = rcgen::CertificateParams::new(vec![name.into()]).unwrap();
    let cert = params.self_signed(&key).unwrap();
    let cert_path = dir.join("cert.pem");
    let key_path = dir.join("key.pem");
    std::fs::write(&cert_path, cert.pem()).unwrap();
    std::fs::write(&key_path, key.serialize_pem()).unwrap();
    (cert_path, key_path)
}

struct Running {
    quic: std::net::SocketAddr,
    trigger: moq_relay::shutdown::Trigger,
    join: tokio::task::JoinHandle<anyhow::Result<()>>,
}

async fn start(dir: &Path) -> (Running, moq_relay::auth::Admissions) {
    let (cert, key) = cert_pair(dir, "localhost");
    moq_tokio::crypto::install_default().unwrap();
    let mut config = Config::default();
    config.listen.bind = Some("127.0.0.1:0".parse().unwrap());
    config.listen.tls.cert = vec![cert];
    config.listen.tls.key = vec![key];
    config.web.ws = false;
    let mut relay = Relay::load(config).await.unwrap().with_signals(false);
    let quic = relay.quic_addr().unwrap();
    let trigger = relay.shutdown_trigger().clone();
    let admissions = relay.admissions().unwrap();
    let ready = relay.ready();
    let join = tokio::spawn(relay.run());
    ready.wait().await.unwrap();
    (Running { quic, trigger, join }, admissions)
}

fn client() -> moq_tokio::Client {
    let mut config = moq_tokio::connect::Config::default();
    config.tls.insecure = Some(true);
    config.bind = Some("127.0.0.1:0".parse().unwrap());
    config.init(Default::default()).unwrap().with_reconnect(false)
}

fn owner() -> String {
    bs58::encode([9u8; 32]).into_string()
}

fn token(key: &Key, root: &str, seconds: u64) -> String {
    let now = kio::clock::wall();
    let claims = Claims::default()
        .with_root(root)
        .with_publish(["**".parse().unwrap()])
        .with_subscribe(["**".parse().unwrap()])
        .with_issued(now)
        .with_expires(now + Duration::from_secs(seconds));
    key.sign(&claims).unwrap()
}

#[tokio::test]
async fn tokenless_webtransport_is_refused_and_sigterm_stops_a_second_session() {
    let dir = tempfile::tempdir().unwrap();
    let (running, admissions) = start(dir.path()).await;
    let key = Key::generate(Algorithm::EdDSA, None).unwrap();
    let root = format!("t/{}", owner());
    let keys = Arc::new(Mutex::new(KeySet {
        keys: vec![Arc::new(key.public().unwrap())],
    }));
    let draining = Arc::new(AtomicBool::new(false));
    let keys_ok = Arc::new(AtomicBool::new(true));
    mjolnir_relay::spawn_web_decider(
        admissions,
        keys,
        draining.clone(),
        keys_ok,
        Duration::from_secs(3600),
    );

    let url: url::Url = format!("https://{}/", running.quic).parse().unwrap();
    let refused = client().connect(url).established().await;
    assert!(refused.is_err(), "tokenless session was admitted");

    let good = token(&key, &root, 60);
    let url: url::Url = format!("https://{}/?jwt={good}", running.quic).parse().unwrap();
    let session = client().connect(url).established().await.expect("admitted");
    draining.store(true, Ordering::SeqCst);
    let again: url::Url = format!("https://{}/?jwt={good}", running.quic).parse().unwrap();
    let second = client().connect(again).established().await;
    assert!(second.is_err(), "a session during drain was admitted");
    drop(session);
    running.trigger.start();
    let _ = tokio::time::timeout(Duration::from_secs(8), running.join).await;
}

#[tokio::test]
async fn moq_net_at_this_revision_takes_no_in_band_tokens() {
    let dir = tempfile::tempdir().unwrap();
    let (running, admissions) = start(dir.path()).await;
    let key = Key::generate(Algorithm::EdDSA, None).unwrap();
    let root = format!("t/{}", owner());
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
    let good = token(&key, &root, 60);
    let url: url::Url = format!("https://{}/?jwt={good}", running.quic).parse().unwrap();
    let session = client().connect(url).established().await.expect("admitted");
    // moq-net 4a6f522 `Credential::poll_answered` returns `Error::Unsupported`
    // ("a peer that takes no tokens in band"). moq-relay admissions carry the
    // setup token and the `jwt` query only, so this present never becomes an
    // `attached` admission and `web_grant`'s "in-band token" line does not run.
    // The unit test in lib.rs covers that line. Here the live session must
    // still accept another present after the refusal.
    let extra = token(&key, &root, 30);
    let cred = session.auth().add(extra.into_bytes()).expect("present");
    let verdict = tokio::time::timeout(Duration::from_secs(5), cred.closed())
        .await
        .expect("the in-band token got no verdict");
    assert_eq!(verdict.to_string(), "unsupported", "{verdict}");
    let again = session.auth().add(extra_still(&key, &root)).expect("session up");
    let again_verdict = tokio::time::timeout(Duration::from_secs(5), again.closed())
        .await
        .expect("session closed on the second present");
    assert_eq!(again_verdict.to_string(), "unsupported");
    drop(session);
    running.trigger.start();
    let _ = tokio::time::timeout(Duration::from_secs(8), running.join).await;
}

fn extra_still(key: &Key, root: &str) -> Vec<u8> {
    token(key, root, 30).into_bytes()
}
