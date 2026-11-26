#![cfg(target_os = "linux")]

use std::fs;
use std::os::unix::net::UnixDatagram;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use moq_auth::{Algorithm, Key, KeyId, KeySet};
use serde_json::{json, Value};

struct RelayProcess(Child);

impl RelayProcess {
    fn stop(&mut self) {
        let status = Command::new("kill")
            .args(["-TERM", &self.0.id().to_string()])
            .status()
            .unwrap();
        assert!(status.success(), "cannot signal fixture relay");
    }
}

impl Drop for RelayProcess {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn spawn_relay(dir: &Path) -> RelayProcess {
    RelayProcess(
        Command::new(env!("CARGO_BIN_EXE_mjolnir-relay"))
            .env("MJOLNIR_RELAY_HOST", "localhost")
            .env("MJOLNIR_RELAY_BIND", "127.0.0.1:0")
            .env("MJOLNIR_RELAY_TLS_DIR", dir)
            .env("MJOLNIR_RELAY_KEYS", dir.join("keys.json"))
            .env("MJOLNIR_RELAY_KEYS_ACTIVE", dir.join("keys.active"))
            .env("MJOLNIR_RELAY_LOCATOR", dir.join("locator.json"))
            .env("MJOLNIR_RELAY_STATE_DIR", dir)
            .env("MJOLNIR_RELAY_DRAIN_SECONDS", "2")
            .env("NOTIFY_SOCKET", dir.join("notify.sock"))
            .stdout(Stdio::null())
            .spawn()
            .unwrap(),
    )
}

fn prepare_credentials(dir: &Path) {
    let tls_key = rcgen::KeyPair::generate().unwrap();
    let cert = rcgen::CertificateParams::new(vec!["localhost".into()])
        .unwrap()
        .self_signed(&tls_key)
        .unwrap();
    fs::write(dir.join("cert.pem"), cert.pem()).unwrap();
    fs::write(dir.join("key.pem"), tls_key.serialize_pem()).unwrap();

    let kid = KeyId::decode("room-kid").unwrap();
    let signing = Key::generate(Algorithm::EdDSA, Some(kid)).unwrap();
    let keys = KeySet {
        keys: vec![std::sync::Arc::new(signing.public().unwrap())],
    };
    fs::write(dir.join("keys.json"), keys.to_str().unwrap()).unwrap();
}

#[test]
#[ignore = "the relay requires root-owned verifier files; run in a Linux user namespace"]
fn publishes_the_bound_identity_before_ready_and_withdraws_it_at_drain() {
    let dir = tempfile::tempdir().unwrap();
    prepare_credentials(dir.path());
    let ready = UnixDatagram::bind(dir.path().join("notify.sock")).unwrap();
    ready.set_nonblocking(true).unwrap();
    let locator_path = dir.path().join("locator.json");
    let previous_locator = json!({"host": "old.example", "endpoint_id": "old"});

    for _ in 0..2 {
        let secret = iroh::SecretKey::generate();
        fs::write(dir.path().join("iroh-secret"), secret.to_bytes()).unwrap();
        let expected = json!({"host": "localhost", "endpoint_id": secret.public().to_string()});
        fs::write(&locator_path, previous_locator.to_string()).unwrap();
        let mut relay = spawn_relay(dir.path());
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            match fs::read(&locator_path) {
                Ok(bytes) => {
                    let seen: Value = serde_json::from_slice(&bytes)
                        .expect("a runtime locator reader saw a partial document");
                    assert!(seen == previous_locator || seen == expected);
                }
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
                Err(err) => panic!("could not read fixture locator: {err}"),
            }
            let mut message = [0; 32];
            match ready.recv(&mut message) {
                Ok(len) => {
                    assert_eq!(&message[..len], b"READY=1\n");
                    break;
                }
                Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(err) => panic!("could not receive fixture readiness: {err}"),
            }
            assert!(
                relay.0.try_wait().unwrap().is_none(),
                "relay exited before readiness"
            );
            assert!(Instant::now() < deadline, "relay did not signal readiness");
            std::thread::sleep(Duration::from_millis(5));
        }

        let published: Value = serde_json::from_slice(&fs::read(&locator_path).unwrap()).unwrap();
        assert_eq!(
            published, expected,
            "readiness still points to the old relay"
        );
        relay.stop();
        let deadline = Instant::now() + Duration::from_secs(1);
        while locator_path.exists() {
            assert!(
                Instant::now() < deadline,
                "locator still present during drain"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(
            relay.0.try_wait().unwrap().is_none(),
            "relay exited without draining"
        );
        assert!(relay.0.wait().unwrap().success());
        assert!(!locator_path.exists());
    }
}

#[test]
fn failed_start_discards_an_old_locator() {
    let dir = tempfile::tempdir().unwrap();
    let locator_path = dir.path().join("locator.json");
    fs::write(
        &locator_path,
        br#"{"host":"old.example","endpoint_id":"old"}"#,
    )
    .unwrap();

    let mut relay = spawn_relay(dir.path());
    assert!(
        !relay.0.wait().unwrap().success(),
        "relay started without keys"
    );
    assert!(
        !locator_path.exists(),
        "failed startup kept the old locator"
    );
}
