//! Agent SDK HTTP server for in-VM agent applications.
//!
//! Provides a simple HTTP API on localhost:5001 for agents running inside the VM
//! to communicate with the host orchestrator via vsock messages.
//!
//! Endpoints:
//! - POST /spawn - Spawn a sub-agent VM
//! - POST /snapshot - Create a snapshot of this VM
//! - POST /emit - Emit an event to the host

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_vsock::VsockStream;
use tracing::{error, info, warn};

use crate::protocol::{VsockRequest, VsockResponse};

const AGENT_SDK_PORT: u16 = 5001;
const VSOCK_HOST_CID: u32 = 2; // CID 2 is the host
const VSOCK_PORT: u32 = 5000;

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
    let response = format!(
        "HTTP/1.1 {} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
        status,
        body.len(),
        body
    );
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

/// Send a message over vsock and receive the response.
async fn send_vsock_request(
    request: &VsockRequest,
) -> Result<VsockResponse, Box<dyn std::error::Error + Send + Sync>> {
    // Connect to host vsock
    let mut stream = VsockStream::connect(VSOCK_HOST_CID, VSOCK_PORT).await?;

    // Serialize request
    let json = serde_json::to_vec(request)?;
    let length = json.len() as u32;

    // Send on channel 0 with new wire format: [channel][length][payload]
    AsyncWriteExt::write_all(&mut stream, &[0]).await?; // Channel 0
    AsyncWriteExt::write_all(&mut stream, &length.to_be_bytes()).await?;
    AsyncWriteExt::write_all(&mut stream, &json).await?;
    AsyncWriteExt::flush(&mut stream).await?;

    // Read response header
    let mut header = [0u8; 5];
    AsyncReadExt::read_exact(&mut stream, &mut header).await?;
    let _response_channel = header[0];
    let response_length = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;

    // Read response body
    let mut response_buf = vec![0u8; response_length];
    AsyncReadExt::read_exact(&mut stream, &mut response_buf).await?;

    // Parse response
    let response: VsockResponse = serde_json::from_slice(&response_buf)?;

    Ok(response)
}

/// Run the agent SDK HTTP server.
///
/// This provides a localhost-only HTTP API for agents running inside the VM
/// to interact with the host orchestrator.
pub async fn run_agent_sdk() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Spawn a background task to run the HTTP server
    tokio::task::spawn_blocking(|| {
        match run_agent_sdk_blocking() {
            Ok(_) => info!("Agent SDK server exited"),
            Err(e) => error!("Agent SDK server error: {}", e),
        }
    });

    Ok(())
}

fn run_agent_sdk_blocking() -> Result<(), Box<dyn std::error::Error>> {
    let listener = TcpListener::bind(("127.0.0.1", AGENT_SDK_PORT))?;
    listener.set_nonblocking(false)?;

    info!("Agent SDK HTTP server listening on 127.0.0.1:{}", AGENT_SDK_PORT);

    for stream in listener.incoming() {
        match stream {
            Ok(mut stream) => {
                // Parse HTTP request
                let request = match parse_http_request(&mut stream) {
                    Some(req) => req,
                    None => {
                        warn!("Failed to parse HTTP request");
                        send_http_response(&mut stream, 400, r#"{"error":"Bad request"}"#);
                        continue;
                    }
                };

                info!("Agent SDK request: {} {}", request.method, request.path);

                // Route request - spawn async handler
                let runtime = tokio::runtime::Handle::current();
                match (request.method.as_str(), request.path.as_str()) {
                    ("POST", "/spawn") => {
                        runtime.block_on(handle_spawn(&mut stream, &request));
                    }
                    ("POST", "/snapshot") => {
                        runtime.block_on(handle_snapshot(&mut stream, &request));
                    }
                    ("POST", "/emit") => {
                        runtime.block_on(handle_emit(&mut stream, &request));
                    }
                    ("GET", "/health") => {
                        send_http_response(&mut stream, 200, r#"{"status":"ok"}"#);
                    }
                    _ => {
                        send_http_response(&mut stream, 404, r#"{"error":"Not found"}"#);
                    }
                }
            }
            Err(e) => {
                error!("Failed to accept connection: {}", e);
            }
        }
    }

    Ok(())
}

async fn handle_spawn(stream: &mut std::net::TcpStream, request: &HttpRequest) {
    // Parse request body
    let opts: serde_json::Value = match serde_json::from_str(&request.body) {
        Ok(v) => v,
        Err(e) => {
            warn!("Invalid JSON in spawn request: {}", e);
            send_http_response(stream, 400, r#"{"error":"Invalid JSON"}"#);
            return;
        }
    };

    // Generate request ID
    let id = uuid::Uuid::new_v4().to_string();

    // Send spawn_sub_agent request over vsock
    let req = VsockRequest::SpawnSubAgent {
        id: id.clone(),
        opts,
    };

    match send_vsock_request(&req).await {
        Ok(VsockResponse::SpawnSubAgentResponse { id: _, vm_id }) => {
            let response = serde_json::json!({
                "status": "ok",
                "vm_id": vm_id
            });
            send_http_response(stream, 200, &response.to_string());
        }
        Ok(other) => {
            warn!("Unexpected response to spawn_sub_agent: {:?}", other);
            send_http_response(stream, 500, r#"{"error":"Unexpected response"}"#);
        }
        Err(e) => {
            error!("Failed to send spawn_sub_agent: {}", e);
            send_http_response(stream, 500, r#"{"error":"Communication error"}"#);
        }
    }
}

async fn handle_snapshot(stream: &mut std::net::TcpStream, request: &HttpRequest) {
    // Parse request body
    let body: serde_json::Value = match serde_json::from_str(&request.body) {
        Ok(v) => v,
        Err(e) => {
            warn!("Invalid JSON in snapshot request: {}", e);
            send_http_response(stream, 400, r#"{"error":"Invalid JSON"}"#);
            return;
        }
    };

    let name = body.get("name")
        .and_then(|v| v.as_str())
        .unwrap_or("snapshot")
        .to_string();

    // Generate request ID
    let id = uuid::Uuid::new_v4().to_string();

    // Send snapshot_self request over vsock
    let req = VsockRequest::SnapshotSelf {
        id: id.clone(),
        name,
    };

    match send_vsock_request(&req).await {
        Ok(VsockResponse::SnapshotSelfResponse { id: _, ok }) => {
            let response = serde_json::json!({
                "status": if ok { "ok" } else { "failed" }
            });
            send_http_response(stream, 200, &response.to_string());
        }
        Ok(other) => {
            warn!("Unexpected response to snapshot_self: {:?}", other);
            send_http_response(stream, 500, r#"{"error":"Unexpected response"}"#);
        }
        Err(e) => {
            error!("Failed to send snapshot_self: {}", e);
            send_http_response(stream, 500, r#"{"error":"Communication error"}"#);
        }
    }
}

async fn handle_emit(stream: &mut std::net::TcpStream, request: &HttpRequest) {
    // Parse request body
    let body: serde_json::Value = match serde_json::from_str(&request.body) {
        Ok(v) => v,
        Err(e) => {
            warn!("Invalid JSON in emit request: {}", e);
            send_http_response(stream, 400, r#"{"error":"Invalid JSON"}"#);
            return;
        }
    };

    let event = body.get("event")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let payload = body.get("payload")
        .cloned()
        .unwrap_or(serde_json::json!({}));

    // Generate request ID
    let id = uuid::Uuid::new_v4().to_string();

    // Send emit_event request over vsock
    let req = VsockRequest::EmitEvent {
        id: id.clone(),
        event,
        payload,
    };

    match send_vsock_request(&req).await {
        Ok(VsockResponse::EventAck { id: _ }) => {
            let response = serde_json::json!({
                "status": "ok"
            });
            send_http_response(stream, 200, &response.to_string());
        }
        Ok(other) => {
            warn!("Unexpected response to emit_event: {:?}", other);
            send_http_response(stream, 500, r#"{"error":"Unexpected response"}"#);
        }
        Err(e) => {
            error!("Failed to send emit_event: {}", e);
            send_http_response(stream, 500, r#"{"error":"Communication error"}"#);
        }
    }
}
