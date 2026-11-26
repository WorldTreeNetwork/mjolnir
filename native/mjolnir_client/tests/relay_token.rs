//! Exercise the command with an isolated saved session via XDG_CONFIG_HOME.
#![cfg(target_os = "linux")]

use std::fs;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

const SESSION: &str = "synthetic-session-marker";
const RESPONSE: &str = " { \"token\": \"synthetic-room-marker\", \"future\": 1 }\n";
const ROUTE: &str = "POST /api/relay/rooms/room_1/participants/alice-2/token HTTP/1.1";

struct SavedSession(PathBuf);

impl SavedSession {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "mj-relay-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        fs::create_dir(path.join("mjolnir")).unwrap();
        fs::write(
            path.join("mjolnir/token.json"),
            serde_json::json!({
                "access_token": SESSION,
                "issuer": "http://127.0.0.1",
            })
            .to_string(),
        )
        .unwrap();
        Self(path)
    }

    fn command(&self, api: &str) -> Command {
        let mut cli = Command::new(env!("CARGO_BIN_EXE_mjolnir"));
        cli.env("XDG_CONFIG_HOME", &self.0)
            .env_remove("MJOLNIR_PROFILE")
            .env_remove("MJOLNIR_TOKEN")
            .env("NO_PROXY", "127.0.0.1")
            .args(["relay", "token", "--api", api]);
        cli
    }
}

impl Drop for SavedSession {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn mock_mint(status: Option<&'static str>, body: &'static str, json: bool) -> Output {
    let session = SavedSession::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let api = format!("http://{}/", listener.local_addr().unwrap());
    let server = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                    if Instant::now() >= deadline {
                        return false;
                    }
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(err) => panic!("mock listener failed: {err}"),
            }
        };
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let mut request = Vec::new();
        let mut chunk = [0; 1024];
        while !request.ends_with(b"\r\n\r\n{}") {
            let n = stream.read(&mut chunk).unwrap();
            assert_ne!(n, 0, "incomplete mint request");
            request.extend_from_slice(&chunk[..n]);
        }
        let headers = std::str::from_utf8(&request).unwrap();
        assert_eq!(headers.lines().next(), Some(ROUTE));
        assert!(
            headers
                .to_ascii_lowercase()
                .contains(&format!("\r\nauthorization: bearer {SESSION}\r\n")),
            "request did not use the synthetic saved session"
        );
        assert!(headers.contains("\r\ncontent-type: application/json\r\n"));

        if let Some(status) = status {
            write!(
                stream,
                "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        }
        true
    });
    let mut cli = session.command(&api);
    cli.args(["room_1", "alice-2"]);
    if json {
        cli.arg("--json");
    }
    let output = cli.output().unwrap();
    assert!(
        server.join().unwrap(),
        "no mint request: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    output
}

fn assert_safe_failure(output: Output, hint: &str) {
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains(hint), "missing expected diagnostic: {hint}");
    assert!(!stderr.contains(SESSION));
    assert!(!stderr.contains("synthetic-room-marker"));
}

#[test]
fn prints_only_the_token_by_default() {
    let output = mock_mint(Some("200 OK"), RESPONSE, false);
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    assert_eq!(output.stdout, b"synthetic-room-marker\n");
}

#[test]
fn prints_the_original_json_bytes_including_extensions() {
    let output = mock_mint(Some("200 OK"), RESPONSE, true);
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    assert_eq!(output.stdout, RESPONSE.as_bytes());
}

#[test]
fn refuses_invalid_segments_before_opening_a_connection() {
    let session = SavedSession::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let api = format!("http://{}", listener.local_addr().unwrap());
    for (room, participant) in [
        ("room/other", "alice"),
        ("room", "alice%2Fother"),
        ("room", "alice\n"),
    ] {
        let output = session
            .command(&api)
            .args([room, participant])
            .output()
            .unwrap();
        assert_safe_failure(output, "1 to 64");
        assert_eq!(
            listener.accept().unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
    }
}

#[test]
fn reports_distinct_http_hints_without_response_bodies() {
    for (status, hint) in [
        ("401 Unauthorized", "401 Unauthorized. Run `mj login`"),
        (
            "403 Forbidden",
            "403 Forbidden. A user session with relay:join",
        ),
        (
            "503 Service Unavailable",
            "503 Service Unavailable. The relay may be unconfigured",
        ),
    ] {
        assert_safe_failure(mock_mint(Some(status), RESPONSE, true), hint);
    }
}

#[test]
fn discards_transport_errors_and_invalid_success_responses() {
    assert_safe_failure(
        mock_mint(None, "", false),
        "Could not reach the room-token API",
    );
    for body in [
        "synthetic-room-marker",
        r#"{"future":"synthetic-room-marker"}"#,
        r#"{"token":"synthetic-room-marker\n"}"#,
    ] {
        assert_safe_failure(
            mock_mint(Some("200 OK"), body, true),
            "The room-token API returned an invalid response",
        );
    }
}
