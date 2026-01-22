//! Mjolnir Guest Agent
//!
//! Runs inside the Firecracker VM and handles commands from the host
//! via vsock.

use serde::{Deserialize, Serialize};
use std::process::Command;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_vsock::VsockListener;
use tracing::{error, info, warn};

const VSOCK_PORT: u32 = 5000;
// VMADDR_CID_ANY (0xFFFFFFFF / -1) means accept connections from any CID
const VMADDR_CID_ANY: u32 = 0xFFFFFFFF;

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Request {
    #[serde(rename = "exec")]
    Exec { id: String, command: String },
    #[serde(rename = "ping")]
    Ping { id: String },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum Response {
    #[serde(rename = "exec_response")]
    ExecResponse {
        id: String,
        exit_code: i32,
        stdout: String,
        stderr: String,
    },
    #[serde(rename = "pong")]
    Pong { id: String },
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    info!("Mjolnir guest agent starting on vsock port {}", VSOCK_PORT);

    let mut listener = VsockListener::bind(VMADDR_CID_ANY, VSOCK_PORT)?;

    info!("Listening for connections...");

    loop {
        match listener.accept().await {
            Ok((stream, addr)) => {
                info!("Accepted connection from {:?}", addr);
                tokio::spawn(handle_connection(stream));
            }
            Err(e) => {
                error!("Failed to accept connection: {}", e);
            }
        }
    }
}

async fn handle_connection(mut stream: tokio_vsock::VsockStream) {
    let mut buf = vec![0u8; 65536];

    loop {
        // Read length prefix (4 bytes, big-endian)
        match stream.read_exact(&mut buf[..4]).await {
            Ok(_) => {}
            Err(e) => {
                if e.kind() != std::io::ErrorKind::UnexpectedEof {
                    error!("Failed to read length: {}", e);
                }
                return;
            }
        }

        let length = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;

        if length > buf.len() {
            error!("Message too large: {}", length);
            return;
        }

        // Read message body
        if let Err(e) = stream.read_exact(&mut buf[..length]).await {
            error!("Failed to read message: {}", e);
            return;
        }

        // Parse and handle request
        let response = match serde_json::from_slice::<Request>(&buf[..length]) {
            Ok(request) => handle_request(request),
            Err(e) => {
                warn!("Failed to parse request: {}", e);
                continue;
            }
        };

        // Send response
        if let Err(e) = send_response(&mut stream, &response).await {
            error!("Failed to send response: {}", e);
            return;
        }
    }
}

fn handle_request(request: Request) -> Response {
    match request {
        Request::Exec { id, command } => {
            info!("Executing command: {}", command);

            let output = Command::new("sh").arg("-c").arg(&command).output();

            match output {
                Ok(output) => Response::ExecResponse {
                    id,
                    exit_code: output.status.code().unwrap_or(-1),
                    stdout: String::from_utf8_lossy(&output.stdout).to_string(),
                    stderr: String::from_utf8_lossy(&output.stderr).to_string(),
                },
                Err(e) => Response::ExecResponse {
                    id,
                    exit_code: -1,
                    stdout: String::new(),
                    stderr: format!("Failed to execute: {}", e),
                },
            }
        }
        Request::Ping { id } => {
            info!("Received ping");
            Response::Pong { id }
        }
    }
}

async fn send_response(
    stream: &mut tokio_vsock::VsockStream,
    response: &Response,
) -> Result<(), Box<dyn std::error::Error>> {
    let json = serde_json::to_vec(response)?;
    let length = json.len() as u32;

    stream.write_all(&length.to_be_bytes()).await?;
    stream.write_all(&json).await?;
    stream.flush().await?;

    Ok(())
}
