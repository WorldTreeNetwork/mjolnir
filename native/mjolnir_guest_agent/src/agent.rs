//! Agent SDK HTTP server for in-VM agent applications.
//!
//! Provides a simple HTTP API on localhost:5001 for agents running inside the VM
//! to communicate with the host orchestrator via the existing vsock connection.
//!
//! Endpoints:
//! - POST /spawn - Spawn a sub-agent VM
//! - POST /snapshot - Create a snapshot of this VM
//! - POST /emit - Emit an event to the host
//! - GET /health - Health check

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tracing::{error, info, warn};

use crate::vsock::{BridgeHolder, MessageInbox, MessageNotify};

const AGENT_SDK_PORT: u16 = 5001;
const MAX_BODY_SIZE: usize = 1_048_576; // 1MB
const MAX_CONNECTIONS: usize = 16;

/// Minimal HTTP request parser
struct HttpRequest {
    method: String,
    path: String,
    body: String,
}

fn parse_http_request(stream: &mut std::net::TcpStream) -> Option<HttpRequest> {
    let mut reader = BufReader::new(stream.try_clone().ok()?);
    let mut lines = Vec::new();

    // Read headers
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).is_err() {
            return None;
        }
        if line == "\r\n" || line == "\n" {
            break;
        }
        lines.push(line);
    }

    if lines.is_empty() {
        return None;
    }

    // Parse request line
    let parts: Vec<&str> = lines[0].split_whitespace().collect();
    if parts.len() < 2 {
        return None;
    }

    let method = parts[0].to_string();
    let path = parts[1].to_string();

    // Find Content-Length
    let mut content_length = 0;
    for line in &lines[1..] {
        if line.to_lowercase().starts_with("content-length:") {
            if let Some(len_str) = line.split(':').nth(1) {
                content_length = len_str.trim().parse().unwrap_or(0);
            }
        }
    }

    // Reject oversized bodies
    if content_length > MAX_BODY_SIZE {
        return None;
    }

    // Read body
    let mut body = vec![0u8; content_length];
    if content_length > 0 {
        reader.read_exact(&mut body).ok()?;
    }

    Some(HttpRequest {
        method,
        path,
        body: String::from_utf8_lossy(&body).to_string(),
    })
}

fn send_http_response(stream: &mut std::net::TcpStream, status: u16, body: &str) {
    let status_text = match status {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        _ => "OK",
    };
    let response = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
        status,
        status_text,
        body.len(),
        body
    );
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

/// Send a request via the agent bridge and wait for the response.
async fn send_bridge_request(
    bridge_holder: &BridgeHolder,
    request: serde_json::Value,
) -> Result<serde_json::Value, (u16, String)> {
    let bridge = {
        let guard = bridge_holder.read().await;
        Arc::clone(
            guard
                .as_ref()
                .ok_or((503, r#"{"error":"No active vsock connection"}"#.to_string()))?,
        )
    };

    bridge.send_request(request).await.map_err(|e| {
        error!("Bridge request failed: {}", e);
        let body = serde_json::json!({"error": e.to_string()});
        (502, body.to_string())
    })
}

/// Run the agent SDK HTTP server.
///
/// This provides a localhost-only HTTP API for agents running inside the VM
/// to interact with the host orchestrator.
pub async fn run_agent_sdk(
    bridge_holder: BridgeHolder,
    message_inbox: MessageInbox,
    message_notify: MessageNotify,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Spawn a background task to run the HTTP server
    tokio::task::spawn_blocking(move || {
        match run_agent_sdk_blocking(bridge_holder, message_inbox, message_notify) {
            Ok(_) => info!("Agent SDK server exited"),
            Err(e) => error!("Agent SDK server error: {}", e),
        }
    });

    Ok(())
}

fn run_agent_sdk_blocking(
    bridge_holder: BridgeHolder,
    message_inbox: MessageInbox,
    message_notify: MessageNotify,
) -> Result<(), Box<dyn std::error::Error>> {
    let listener = TcpListener::bind(("127.0.0.1", AGENT_SDK_PORT))?;
    listener.set_nonblocking(false)?;

    info!(
        "Agent SDK HTTP server listening on 127.0.0.1:{}",
        AGENT_SDK_PORT
    );

    let runtime = tokio::runtime::Handle::current();
    let active = Arc::new(AtomicUsize::new(0));

    for stream in listener.incoming() {
        match stream {
            Ok(mut stream) => {
                let current = active.fetch_add(1, Ordering::AcqRel);
                if current >= MAX_CONNECTIONS {
                    active.fetch_sub(1, Ordering::AcqRel);
                    send_http_response(&mut stream, 503, r#"{"error":"Too many connections"}"#);
                    continue;
                }
                let bridge = bridge_holder.clone();
                let inbox = message_inbox.clone();
                let notify = message_notify.clone();
                let rt = runtime.clone();
                let active = active.clone();
                std::thread::spawn(move || {
                    handle_connection(stream, &bridge, &inbox, &notify, &rt);
                    active.fetch_sub(1, Ordering::AcqRel);
                });
            }
            Err(e) => {
                error!("Failed to accept connection: {}", e);
            }
        }
    }

    Ok(())
}

fn handle_connection(
    mut stream: std::net::TcpStream,
    bridge_holder: &BridgeHolder,
    message_inbox: &MessageInbox,
    message_notify: &MessageNotify,
    runtime: &tokio::runtime::Handle,
) {
    let request = match parse_http_request(&mut stream) {
        Some(req) => req,
        None => {
            warn!("Failed to parse HTTP request");
            send_http_response(&mut stream, 400, r#"{"error":"Bad request"}"#);
            return;
        }
    };

    info!("Agent SDK request: {} {}", request.method, request.path);

    // Extract path without query string for routing
    let path = request.path.split('?').next().unwrap_or(&request.path);

    match (request.method.as_str(), path) {
        ("POST", "/spawn") => {
            runtime.block_on(handle_spawn(&mut stream, &request, bridge_holder));
        }
        ("POST", "/snapshot") => {
            runtime.block_on(handle_snapshot(&mut stream, &request, bridge_holder));
        }
        ("POST", "/emit") => {
            runtime.block_on(handle_emit(&mut stream, &request, bridge_holder));
        }
        ("POST", "/send") => {
            runtime.block_on(handle_send(&mut stream, &request, bridge_holder));
        }
        ("GET", "/recv") => {
            runtime.block_on(handle_recv(
                &mut stream,
                &request,
                message_inbox,
                message_notify,
            ));
        }
        ("GET", "/messages") => {
            runtime.block_on(handle_messages(&mut stream, message_inbox));
        }
        ("POST", "/ack") => {
            runtime.block_on(handle_ack(&mut stream, &request, message_inbox, bridge_holder));
        }
        ("POST", "/done") => {
            runtime.block_on(handle_done(&mut stream, message_inbox, bridge_holder));
        }
        ("GET", "/health") => {
            send_http_response(&mut stream, 200, r#"{"status":"ok"}"#);
        }
        _ => {
            send_http_response(&mut stream, 404, r#"{"error":"Not found"}"#);
        }
    }
}

async fn handle_spawn(
    stream: &mut std::net::TcpStream,
    request: &HttpRequest,
    bridge_holder: &BridgeHolder,
) {
    let opts: serde_json::Value = match serde_json::from_str(&request.body) {
        Ok(v) => v,
        Err(e) => {
            warn!("Invalid JSON in spawn request: {}", e);
            send_http_response(stream, 400, r#"{"error":"Invalid JSON"}"#);
            return;
        }
    };

    let id = uuid::Uuid::new_v4().to_string();
    let req = serde_json::json!({
        "type": "spawn_sub_agent",
        "id": id,
        "opts": opts
    });

    match send_bridge_request(bridge_holder, req).await {
        Ok(response) => {
            if let Some(err) = response.get("error").and_then(|v| v.as_str()) {
                let body = serde_json::json!({"error": err});
                send_http_response(stream, 500, &body.to_string());
            } else {
                let vm_id = response.get("vm_id").and_then(|v| v.as_str()).unwrap_or("");
                let body = serde_json::json!({"status": "ok", "vm_id": vm_id});
                send_http_response(stream, 200, &body.to_string());
            }
        }
        Err((status, body)) => {
            send_http_response(stream, status, &body);
        }
    }
}

async fn handle_snapshot(
    stream: &mut std::net::TcpStream,
    request: &HttpRequest,
    bridge_holder: &BridgeHolder,
) {
    let body: serde_json::Value = match serde_json::from_str(&request.body) {
        Ok(v) => v,
        Err(e) => {
            warn!("Invalid JSON in snapshot request: {}", e);
            send_http_response(stream, 400, r#"{"error":"Invalid JSON"}"#);
            return;
        }
    };

    let name = body
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or("snapshot")
        .to_string();

    let id = uuid::Uuid::new_v4().to_string();
    let req = serde_json::json!({
        "type": "snapshot_self",
        "id": id,
        "name": name
    });

    match send_bridge_request(bridge_holder, req).await {
        Ok(response) => {
            let ok = response
                .get("ok")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            let body = serde_json::json!({"status": if ok { "ok" } else { "failed" }});
            send_http_response(stream, 200, &body.to_string());
        }
        Err((status, body)) => {
            send_http_response(stream, status, &body);
        }
    }
}

async fn handle_emit(
    stream: &mut std::net::TcpStream,
    request: &HttpRequest,
    bridge_holder: &BridgeHolder,
) {
    let body: serde_json::Value = match serde_json::from_str(&request.body) {
        Ok(v) => v,
        Err(e) => {
            warn!("Invalid JSON in emit request: {}", e);
            send_http_response(stream, 400, r#"{"error":"Invalid JSON"}"#);
            return;
        }
    };

    let event = body
        .get("event")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let payload = body
        .get("payload")
        .cloned()
        .unwrap_or(serde_json::json!({}));

    let id = uuid::Uuid::new_v4().to_string();
    let req = serde_json::json!({
        "type": "emit_event",
        "id": id,
        "event": event,
        "payload": payload
    });

    match send_bridge_request(bridge_holder, req).await {
        Ok(_) => {
            let body = serde_json::json!({"status": "ok"});
            send_http_response(stream, 200, &body.to_string());
        }
        Err((status, body)) => {
            send_http_response(stream, status, &body);
        }
    }
}

async fn handle_send(
    stream: &mut std::net::TcpStream,
    request: &HttpRequest,
    bridge_holder: &BridgeHolder,
) {
    let body: serde_json::Value = match serde_json::from_str(&request.body) {
        Ok(v) => v,
        Err(e) => {
            warn!("Invalid JSON in send request: {}", e);
            send_http_response(stream, 400, r#"{"error":"Invalid JSON"}"#);
            return;
        }
    };

    let target_vm_id = match body.get("target_vm_id").and_then(|v| v.as_str()) {
        Some(id) => id.to_string(),
        None => {
            send_http_response(stream, 400, r#"{"error":"target_vm_id is required"}"#);
            return;
        }
    };

    let payload = body
        .get("payload")
        .cloned()
        .unwrap_or(serde_json::json!({}));

    let id = uuid::Uuid::new_v4().to_string();
    let req = serde_json::json!({
        "type": "send_message",
        "id": id,
        "target_vm_id": target_vm_id,
        "payload": payload
    });

    match send_bridge_request(bridge_holder, req).await {
        Ok(response) => {
            let ok = response
                .get("ok")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            if ok {
                let body = serde_json::json!({"status": "ok"});
                send_http_response(stream, 200, &body.to_string());
            } else {
                let error = response
                    .get("error")
                    .and_then(|v| v.as_str())
                    .unwrap_or("unknown error");
                let body = serde_json::json!({"error": error});
                send_http_response(stream, 500, &body.to_string());
            }
        }
        Err((status, body)) => {
            send_http_response(stream, status, &body);
        }
    }
}

async fn handle_recv(
    stream: &mut std::net::TcpStream,
    request: &HttpRequest,
    message_inbox: &MessageInbox,
    message_notify: &MessageNotify,
) {
    // Parse timeout from query string (default 30s)
    let timeout_secs = request
        .path
        .split('?')
        .nth(1)
        .and_then(|qs| {
            qs.split('&')
                .find(|p| p.starts_with("timeout="))
                .and_then(|p| p.strip_prefix("timeout="))
                .and_then(|v| v.parse::<u64>().ok())
        })
        .unwrap_or(30);

    // Register the notification future BEFORE checking the inbox to avoid
    // the lost-wakeup race: if a message arrives between dropping the lock
    // and awaiting notified(), the notification would be lost otherwise.
    let notified = message_notify.notified();
    tokio::pin!(notified);

    // Check inbox first (under lock). Peek only — host mail is not
    // complete until POST /ack.
    {
        let inbox = message_inbox.lock().await;
        if let Some(msg) = inbox.front() {
            let body = serde_json::json!({
                "id": msg.id,
                "from_vm_id": msg.from_vm_id,
                "payload": msg.payload
            });
            send_http_response(stream, 200, &body.to_string());
            return;
        }
    }
    // Lock dropped — but notified future was registered before check,
    // so any notify_waiters() call between here and the select! is captured.

    // Block waiting for a message with timeout
    let result = tokio::select! {
        _ = &mut notified => {
            let inbox = message_inbox.lock().await;
            inbox.front().cloned()
        }
        _ = tokio::time::sleep(std::time::Duration::from_secs(timeout_secs)) => {
            None
        }
    };

    match result {
        Some(msg) => {
            let body = serde_json::json!({
                "id": msg.id,
                "from_vm_id": msg.from_vm_id,
                "payload": msg.payload
            });
            send_http_response(stream, 200, &body.to_string());
        }
        None => {
            send_http_response(stream, 204, "");
        }
    }
}

async fn handle_messages(stream: &mut std::net::TcpStream, message_inbox: &MessageInbox) {
    let messages: Vec<serde_json::Value> = {
        let inbox = message_inbox.lock().await;
        inbox
            .iter()
            .map(|msg| {
                serde_json::json!({
                    "id": msg.id,
                    "from_vm_id": msg.from_vm_id,
                    "payload": msg.payload
                })
            })
            .collect()
    };

    let body = serde_json::json!(messages);
    send_http_response(stream, 200, &body.to_string());
}

async fn handle_ack(
    stream: &mut std::net::TcpStream,
    request: &HttpRequest,
    message_inbox: &MessageInbox,
    bridge_holder: &BridgeHolder,
) {
    let ids: Vec<String> = match serde_json::from_str::<serde_json::Value>(&request.body) {
        Ok(v) => v
            .get("ids")
            .and_then(|x| x.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|x| x.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default(),
        Err(_) => {
            send_http_response(stream, 400, r#"{"error":"Invalid JSON"}"#);
            return;
        }
    };

    {
        let mut inbox = message_inbox.lock().await;
        inbox.retain(|msg| !ids.contains(&msg.id));
    }

    let corr = uuid::Uuid::new_v4().to_string();
    let req = serde_json::json!({
        "type": "ack_messages",
        "id": corr,
        "message_ids": ids
    });

    match send_bridge_request(bridge_holder, req).await {
        Ok(_) => send_http_response(stream, 200, r#"{"ok":true}"#),
        Err((status, body)) => send_http_response(stream, status, &body),
    }
}

async fn handle_done(
    stream: &mut std::net::TcpStream,
    message_inbox: &MessageInbox,
    bridge_holder: &BridgeHolder,
) {
    let pending = {
        let inbox = message_inbox.lock().await;
        inbox.len()
    };
    if pending > 0 {
        let body = serde_json::json!({
            "error": "unacked_mail",
            "unacked": pending
        });
        send_http_response(stream, 409, &body.to_string());
        return;
    }

    let id = uuid::Uuid::new_v4().to_string();
    let req = serde_json::json!({
        "type": "signal_done",
        "id": id
    });

    match send_bridge_request(bridge_holder, req).await {
        Ok(response) => {
            let ok = response
                .get("ok")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            if ok {
                let body = serde_json::json!({"status": "ok"});
                send_http_response(stream, 200, &body.to_string());
            } else {
                let body = serde_json::json!({"error": "done signal rejected"});
                send_http_response(stream, 500, &body.to_string());
            }
        }
        Err((status, body)) => {
            send_http_response(stream, status, &body);
        }
    }
}
