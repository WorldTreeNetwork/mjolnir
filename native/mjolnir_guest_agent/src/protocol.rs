//! Wire protocol messages for vsock and Iroh communication.

use serde::{Deserialize, Serialize};

/// Messages from host to guest (vsock)
#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
pub enum VsockRequest {
    #[serde(rename = "exec")]
    Exec { id: String, command: String },
    #[serde(rename = "ping")]
    Ping { id: String },
    #[serde(rename = "configure_network")]
    ConfigureNetwork { id: String, ip: String },
    #[serde(rename = "get_iroh_status")]
    GetIrohStatus { id: String },
}

/// Messages from guest to host (vsock)
#[derive(Debug, Serialize)]
#[serde(tag = "type")]
pub enum VsockResponse {
    #[serde(rename = "exec_response")]
    ExecResponse {
        id: String,
        exit_code: i32,
        stdout: String,
        stderr: String,
    },
    #[serde(rename = "pong")]
    Pong { id: String },
    #[serde(rename = "iroh_status")]
    IrohStatus {
        id: String,
        ready: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        node_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        ticket: Option<String>,
    },
}

/// Notification sent when Iroh is ready
#[derive(Debug, Serialize)]
pub struct IrohReady {
    #[serde(rename = "type")]
    pub msg_type: &'static str,
    pub node_id: String,
    pub ticket: String,
    pub generated_key: bool,
}

impl IrohReady {
    pub fn new(node_id: String, ticket: String, generated_key: bool) -> Self {
        Self {
            msg_type: "iroh_ready",
            node_id,
            ticket,
            generated_key,
        }
    }
}

