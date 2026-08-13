//! Wire protocol messages for vsock and Iroh communication.

use serde::{Deserialize, Serialize};

/// Metadata about a tmux session.
#[cfg(feature = "full")]
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct TmuxSessionInfo {
    pub session_name: String,
    pub windows: u32,
    pub created: u64,
    pub attached: bool,
}

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
    #[cfg(feature = "iroh")]
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
    #[cfg(feature = "iroh")]
    #[serde(rename = "configure_iroh")]
    ConfigureIroh { id: String, enabled: bool },
    #[serde(rename = "pty_open")]
    PtyOpen {
        id: String,
        rows: u16,
        cols: u16,
        /// Attach the PTY to this tmux session (created on first use) instead of
        /// spawning a private shell. Optional and defaulted so older hosts, which
        /// never send the field, keep getting the private-shell behaviour.
        #[serde(default)]
        session: Option<String>,
    },
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
    #[cfg(feature = "full")]
    #[serde(rename = "terminal_open")]
    TerminalOpen { id: String, session_name: String },
    #[cfg(feature = "full")]
    #[serde(rename = "terminal_read")]
    TerminalRead {
        id: String,
        session_name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        scrollback_lines: Option<i32>,
    },
    #[cfg(feature = "full")]
    #[serde(rename = "terminal_send")]
    TerminalSend {
        id: String,
        session_name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        command: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        keys: Option<String>,
    },
    #[cfg(feature = "full")]
    #[serde(rename = "terminal_send_and_read")]
    TerminalSendAndRead {
        id: String,
        session_name: String,
        command: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        timeout_ms: Option<u64>,
    },
    #[cfg(feature = "full")]
    #[serde(rename = "terminal_list")]
    TerminalList { id: String },
    #[cfg(feature = "full")]
    #[serde(rename = "terminal_close")]
    TerminalClose { id: String, session_name: String },
    #[cfg(feature = "full")]
    #[serde(rename = "configure_secrets_auth")]
    ConfigureSecretsAuth { id: String, authorized_peers: Vec<String> },
    /// Host-escrowed secret injection over vsock (`secrets_mode: :managed`).
    /// Unlike the Iroh ALPN, the host supplies the passphrase directly — used to
    /// create the LUKS volume on first boot and re-open it on dormancy wake.
    /// `init_size_mb` is honored only on creation; `entries` are merged after
    /// mount (host-pushed secret material).
    #[cfg(feature = "full")]
    #[serde(rename = "inject_secrets")]
    InjectSecrets {
        id: String,
        passphrase: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        init_size_mb: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        entries: Option<std::collections::HashMap<String, String>>,
    },
}

/// Messages from guest to host (vsock)
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum VsockResponse {
    /// A request this agent could not parse — unknown action, or a known
    /// action whose shape it predates.
    ///
    /// Sending NOTHING was the old behaviour, and it turned "your guest agent
    /// is too old to understand this" into a host-side timeout: the least
    /// diagnosable failure there is, because a timeout reads as a hung or
    /// wedged guest. That cost a full 60s per call and pointed the
    /// investigation at cryptsetup instead of at the agent version
    /// (mjolnir-azm). `ok: false` puts this in the same shape callers already
    /// match for a rejected request, so it surfaces as a rejection rather
    /// than as an unexpected response.
    #[serde(rename = "error")]
    Error {
        id: String,
        ok: bool,
        error: String,
    },
    #[serde(rename = "exec_response")]
    ExecResponse {
        id: String,
        exit_code: i32,
        stdout: String,
        stderr: String,
    },
    #[serde(rename = "pong")]
    Pong {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        agent: Option<String>,
    },
    #[serde(rename = "boot_status")]
    BootStatus { stage: String, detail: String },
    #[cfg(feature = "iroh")]
    #[serde(rename = "iroh_status")]
    IrohStatus {
        id: String,
        ready: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        node_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        ticket: Option<String>,
    },
    #[cfg(feature = "iroh")]
    #[serde(rename = "configure_iroh_response")]
    ConfigureIrohResponse { id: String, ok: bool },
    #[cfg(feature = "full")]
    #[serde(rename = "inject_secrets_response")]
    InjectSecretsResponse {
        id: String,
        ok: bool,
        created: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
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
    #[cfg(feature = "full")]
    #[serde(rename = "terminal_opened")]
    TerminalOpened {
        id: String,
        session_name: String,
        status: String,
    },
    #[cfg(feature = "full")]
    #[serde(rename = "terminal_output")]
    TerminalOutput {
        id: String,
        content: String,
        pane_rows: u16,
        pane_cols: u16,
        #[serde(skip_serializing_if = "Option::is_none")]
        running_command: Option<String>,
    },
    #[cfg(feature = "full")]
    #[serde(rename = "terminal_sent")]
    TerminalSent { id: String, sent: bool },
    #[cfg(feature = "full")]
    #[serde(rename = "terminal_command_ack")]
    TerminalCommandAck { id: String, status: String },
    #[cfg(feature = "full")]
    #[serde(rename = "terminal_command_output")]
    TerminalCommandOutput {
        id: String,
        output: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        exit_code: Option<i32>,
        duration_ms: u64,
        timed_out: bool,
    },
    #[cfg(feature = "full")]
    #[serde(rename = "terminal_sessions")]
    TerminalSessions {
        id: String,
        sessions: Vec<TmuxSessionInfo>,
    },
    #[cfg(feature = "full")]
    #[serde(rename = "terminal_closed")]
    TerminalClosed { id: String, session_name: String },
    #[cfg(feature = "full")]
    #[serde(rename = "terminal_error")]
    TerminalError { id: String, error: String },
}

/// Notification sent when Iroh is ready
#[cfg(feature = "iroh")]
#[derive(Debug, Clone, Serialize)]
pub struct IrohReady {
    #[serde(rename = "type")]
    pub msg_type: &'static str,
    pub node_id: String,
    pub ticket: String,
    pub generated_key: bool,
}

#[cfg(feature = "iroh")]
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
