//! Disposable relay, verified TLS (the relay cert is the only root), mint-shaped token.
//! Coloured frames are not produced here: this process has no RTP source.
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use moq_auth::{Algorithm, Claims, Key, KeySet};
use moq_relay::{Config, Relay};

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

#[tokio::test]
async fn verified_root_dials_and_a_foreign_root_does_not() {
    let dir = tempfile::tempdir().unwrap();
    let (cert, key) = cert_pair(dir.path());
    moq_tokio::crypto::install_default().unwrap();
    let mut config = Config::default();
    config.listen.bind = Some("127.0.0.1:0".parse().unwrap());
    config.listen.tls.cert = vec![cert.clone()];
    config.listen.tls.key = vec![key];
    config.web.ws = false;
    let mut relay = Relay::load(config).await.unwrap().with_signals(false);
    let quic = relay.quic_addr().unwrap();
    let admissions = relay.admissions().unwrap();
    let ready = relay.ready();
    let join = tokio::spawn(relay.run());
    ready.wait().await.unwrap();

    let signing = Key::generate(Algorithm::EdDSA, None).unwrap();
    let owner = bs58::encode([9u8; 32]).into_string();
    let root = format!("t/{owner}/~open/standup");
    let now = kio::clock::wall();
    let claims = Claims::default()
        .with_root(&root)
        .with_publish(["alice/**".parse().unwrap()])
        .with_subscribe(["**".parse().unwrap()])
        .with_issued(now)
        .with_expires(now + Duration::from_secs(120));
    let token = signing.sign(&claims).unwrap();
    let keys = Arc::new(Mutex::new(KeySet {
        keys: vec![Arc::new(signing.public().unwrap())],
    }));
    mjolnir_relay::spawn_web_decider(
        admissions,
        keys.clone(),
        Arc::new(AtomicBool::new(false)),
        Arc::new(AtomicBool::new(true)),
        mjolnir_relay::DEFAULT_MAX_TTL,
    );

    let media = moq_webrtc::Server::bind("127.0.0.1:0".parse().unwrap(), Default::default())
        .await
        .unwrap();
    let url = url::Url::parse(&format!("https://localhost:{}", quic.port())).unwrap();
    let edge_url = url.clone();
    let edge = mjolnir_relay::edge::Edge::new(KeySet {
        keys: vec![Arc::new(signing.public().unwrap())],
    });
    edge.set_moq(mjolnir_relay::moq_session::MoqConfig {
        relay: url.clone(),
        tls_root: Some(cert.clone()),
        media,
    });
    let checked = edge
        .admit(
            Some(&token),
            Some(&root),
            None,
            mjolnir_relay::edge::Op::Publish,
            "alice/cam",
            std::time::SystemTime::now(),
        )
        .unwrap();
    assert_eq!(edge.dials(), 0);

    let wrong = tempfile::NamedTempFile::new().unwrap();
    std::fs::write(wrong.path(), "not a cert").unwrap();
    let media = moq_webrtc::Server::bind("127.0.0.1:0".parse().unwrap(), Default::default())
        .await
        .unwrap();
    let bad = mjolnir_relay::moq_session::MoqConfig {
        relay: url.clone(),
        tls_root: Some(wrong.path().to_path_buf()),
        media,
    };
    let failed = mjolnir_relay::moq_session::dial(&bad, &token, Duration::from_secs(3)).await;
    assert!(failed.is_err(), "a malformed root must not verify");

    let foreign_key = rcgen::KeyPair::generate().unwrap();
    let foreign_params = rcgen::CertificateParams::new(vec!["localhost".into()]).unwrap();
    let foreign_signed = foreign_params.self_signed(&foreign_key).unwrap();
    let foreign_cert = dir.path().join("foreign.pem");
    std::fs::write(&foreign_cert, foreign_signed.pem()).unwrap();
    let media = moq_webrtc::Server::bind("127.0.0.1:0".parse().unwrap(), Default::default())
        .await
        .unwrap();
    let foreign = mjolnir_relay::moq_session::MoqConfig {
        relay: url.clone(),
        tls_root: Some(foreign_cert),
        media,
    };
    let failed = mjolnir_relay::moq_session::dial(&foreign, &token, Duration::from_secs(3)).await;
    assert!(failed.is_err(), "a different but valid CA must not verify");

    let mut by_addr = edge_url.clone();
    by_addr.set_host(Some("127.0.0.1")).unwrap();
    let media = moq_webrtc::Server::bind("127.0.0.1:0".parse().unwrap(), Default::default())
        .await
        .unwrap();
    let mismatch = mjolnir_relay::moq_session::MoqConfig {
        relay: by_addr,
        tls_root: Some(cert.clone()),
        media,
    };
    let failed = mjolnir_relay::moq_session::dial(&mismatch, &token, Duration::from_secs(3)).await;
    assert!(failed.is_err(), "localhost cert must not match 127.0.0.1");

    let good = mjolnir_relay::moq_session::MoqConfig {
        relay: edge_url.clone(),
        tls_root: Some(cert),
        media: moq_webrtc::Server::bind("127.0.0.1:0".parse().unwrap(), Default::default()).await.unwrap(),
    };
    let dialed = mjolnir_relay::moq_session::dial(&good, &token, Duration::from_secs(5)).await;
    if let Err(err) = &dialed {
        panic!("verified dial: {err}");
    }
    let _ = (checked, edge);
    drop(join);
}
