//! An Iroh session admitted on a short token must close at `exp`.
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};

use iroh::Watcher;
use std::time::Duration;

use moq_auth::{Algorithm, Claims, Key, KeySet};

fn owner() -> String {
    bs58::encode([11u8; 32]).into_string()
}

#[tokio::test]
async fn iroh_session_closes_when_the_token_expires() {
    let dir = tempfile::tempdir().unwrap();
    let key = rcgen::KeyPair::generate().unwrap();
    let params = rcgen::CertificateParams::new(vec!["localhost".into()]).unwrap();
    let cert = params.self_signed(&key).unwrap();
    let cert_path = dir.path().join("cert.pem");
    let key_path = dir.path().join("key.pem");
    std::fs::write(&cert_path, cert.pem()).unwrap();
    std::fs::write(&key_path, key.serialize_pem()).unwrap();
    moq_tokio::crypto::install_default().unwrap();

    let mut config = moq_relay::Config::default();
    config.listen.bind = Some("127.0.0.1:0".parse().unwrap());
    config.listen.tls.cert = vec![cert_path];
    config.listen.tls.key = vec![key_path];
    config.web.ws = false;
    let mut relay = moq_relay::Relay::load(config).await.unwrap().with_signals(false);
    let mut admissions = relay.admissions().unwrap();
    tokio::spawn(async move {
        while let Some(admission) = admissions.next().await {
            admission.refuse(moq_relay::auth::Error::Unavailable("iroh test".into()));
        }
    });
    let cluster = relay.cluster().clone();
    let trigger = relay.shutdown_trigger().clone();
    let ready = relay.ready();
    let join = tokio::spawn(relay.run());
    ready.wait().await.unwrap();

    let signing = Key::generate(Algorithm::EdDSA, None).unwrap();
    let root = format!("t/{}", owner());
    let policy = mjolnir_relay::TokenPolicy {
        keys: Arc::new(Mutex::new(KeySet {
            keys: vec![Arc::new(signing.public().unwrap())],
        })),
        draining: Arc::new(AtomicBool::new(false)),
        keys_ok: Arc::new(AtomicBool::new(true)),
        max_ttl: Duration::from_secs(3600),
    };
    let alpns = moq_transport_iroh::alpns()
        .into_iter()
        .map(<[u8]>::to_vec)
        .collect();
    let endpoint = iroh::Endpoint::builder(iroh::endpoint::presets::N0)
        .secret_key(iroh::SecretKey::generate())
        .alpns(alpns)
        .bind()
        .await
        .unwrap();
    let relay_id = endpoint.id();
    let router = mjolnir_relay::IrohSessions::new(cluster)
        .with_policy(policy)
        .mount(iroh::protocol::Router::builder(endpoint))
        .spawn();

    let now = kio::clock::wall();
    let claims = Claims::default()
        .with_root(&root)
        .with_publish(["**".parse().unwrap()])
        .with_subscribe(["**".parse().unwrap()])
        .with_issued(now)
        .with_expires(now + Duration::from_secs(10));
    let token = signing.sign(&claims).unwrap();

    let client = iroh::Endpoint::builder(iroh::endpoint::presets::N0)
        .bind()
        .await
        .unwrap();
    let node = iroh_live::Node::new(client, iroh_live::NodeConfig::default());
    let config = iroh_live::RelayConfig::iroh(relay_id).with_token(token.parse().unwrap());
    let link = node.attach_relay(config).unwrap();
    let mut status = link.status();
    let connected = tokio::time::timeout(Duration::from_secs(8), async {
        loop {
            if status.get() == iroh_live::RelayStatus::Connected {
                return;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    })
    .await;
    assert!(connected.is_ok(), "session never admitted: {:?}", status.get());

    let closed = tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            if status.get() != iroh_live::RelayStatus::Connected {
                return status.get();
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    })
    .await;
    let still = status.get();
    let _ = router.shutdown().await;
    trigger.start();
    let _ = join.await;
    node.shutdown().await;
    assert!(
        closed.is_ok(),
        "Iroh session still {still:?} fifteen seconds after a ten-second token"
    );
}
