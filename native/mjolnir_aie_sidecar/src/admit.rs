// SPDX-License-Identifier: AGPL-3.0-or-later
//! HTTP client for `/run/mjolnir/aie-admit.sock`. Not operator.sock.

use std::io;
use std::path::Path;

use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

pub async fn enqueue(socket: &Path, nonce: &str, frame: &Value) -> Result<String, String> {
    let body = json!({"nonce": nonce, "frame": frame});
    let v = post(socket, "/enqueue", &body).await?;
    v.get("pending_id")
        .and_then(|x| x.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| format!("enqueue: {v}"))
}

pub async fn admission(
    socket: &Path,
    pending_id: &str,
    attempt_id: &str,
    job_digest: &str,
    resource: &str,
) -> Result<Value, String> {
    let body = json!({
        "pending_id": pending_id,
        "attempt_id": attempt_id,
        "job_digest": job_digest,
        "resource": resource
    });
    post(socket, "/admission", &body).await
}

async fn post(socket: &Path, path: &str, body: &Value) -> Result<Value, String> {
    let payload = body.to_string();
    let req = format!(
        "POST {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
        payload.len()
    );
    let mut stream = UnixStream::connect(socket)
        .await
        .map_err(|e| format!("connect {}: {e}", socket.display()))?;
    stream
        .write_all(req.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    let mut buf = Vec::new();
    stream.read_to_end(&mut buf).await.map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&buf);
    let Some(idx) = text.find("\r\n\r\n") else {
        return Err(format!("bad http: {text}"));
    };
    let body = text[idx + 4..].trim();
    serde_json::from_str(body).map_err(|e| format!("{e}: {body}"))
}

#[allow(dead_code)]
pub fn _io_err(msg: impl Into<String>) -> io::Error {
    io::Error::other(msg.into())
}
