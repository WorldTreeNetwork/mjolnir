//! Wire protocol messages for vsock and Iroh communication.

use serde::{Deserialize, Serialize};

/// Messages from host to guest (vsock)
#[derive(Debug, Deserialize, Serialize)]
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
    #[serde(rename = "configure_ssh")]
    ConfigureSsh { id: String, authorized_keys: String },
    #[serde(rename = "configure_identity")]
    ConfigureIdentity {
        id: String,
        vm_id: String,
        api_url: String,
    },
    #[serde(rename = "configure_iroh")]
    ConfigureIroh { id: String, enabled: bool },
    #[serde(rename = "pty_open")]
    PtyOpen { id: String, rows: u16, cols: u16 },
    #[serde(rename = "pty_resize")]
    PtyResize {
        id: String,
        channel: u8,
        rows: u16,
        cols: u16,
    },
    #[serde(rename = "pty_close")]
    PtyClose { channel: u8 },
    #[serde(rename = "spawn_sub_agent")]
    SpawnSubAgent { id: String, opts: serde_json::Value },
    #[serde(rename = "snapshot_self")]
    SnapshotSelf { id: String, name: String },
    #[serde(rename = "emit_event")]
    EmitEvent {
        id: String,
        event: String,
        payload: serde_json::Value,
    },
    #[serde(rename = "send_message")]
    SendMessage {
        id: String,
        target_vm_id: String,
        payload: serde_json::Value,
    },
    #[serde(rename = "deliver_message")]
    DeliverMessage {
        id: String,
        from_vm_id: String,
        payload: serde_json::Value,
    },
    #[serde(rename = "signal_done")]
    SignalDone { id: String },
    #[serde(rename = "signal_done_ack")]
    SignalDoneAck { id: String, ok: bool },
}

/// Messages from guest to host (vsock)
#[derive(Debug, Serialize, Deserialize)]
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
    #[serde(rename = "configure_iroh_response")]
    ConfigureIrohResponse { id: String, ok: bool },
    #[serde(rename = "pty_opened")]
    PtyOpened { id: String, channel: u8 },
    #[serde(rename = "pty_closed")]
    PtyClosed { channel: u8 },
    #[serde(rename = "spawn_sub_agent_response")]
    SpawnSubAgentResponse { id: String, vm_id: String },
    #[serde(rename = "snapshot_self_response")]
    SnapshotSelfResponse { id: String, ok: bool },
    #[serde(rename = "event_ack")]
    EventAck { id: String },
    #[serde(rename = "send_message_response")]
    SendMessageResponse {
        id: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    #[serde(rename = "deliver_message_ack")]
    DeliverMessageAck { id: String },
}

/// Notification sent when Iroh is ready
#[derive(Debug, Clone, Serialize)]
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
