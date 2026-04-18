//! MCP (Model Context Protocol) server for Mjolnir VM management.
//!
//! Runs over stdio, proxying authenticated HTTP requests to the remote
//! Mjolnir API. Reuses the CLI's config and auth modules.
//!
//! Usage:
//!   mjolnir mcp-serve              # uses default profile
//!   mjolnir mcp-serve --api http://localhost:4000

use std::sync::{Arc, RwLock};

use rmcp::{
    handler::server::router::tool::ToolRouter,
    handler::server::wrapper::Parameters,
    model::*,
    schemars, tool, tool_handler, tool_router, ServerHandler,
};
use serde::Deserialize;

use crate::{auth, config};

// ── Service ──

#[derive(Debug, Clone)]
pub struct MjolnirMcpService {
    tool_router: ToolRouter<Self>,
    api_base: Arc<RwLock<String>>,
    profile_name: Arc<RwLock<String>>,
}

// ── Parameter structs ──

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct SpawnVmParams {
    #[schemars(description = "Base rootfs image name (e.g. 'ubuntu-24.04').")]
    pub base_image: Option<String>,
    #[schemars(description = "RAM in MB (128-8192). Default: 512.")]
    pub memory_mb: Option<i64>,
    #[schemars(description = "Virtual CPUs (1-8). Default: 1.")]
    pub vcpus: Option<i64>,
    #[schemars(description = "SSH public key to inject.")]
    pub ssh_public_key: Option<String>,
    #[schemars(description = "Restore from named snapshot instead of fresh base.")]
    pub snapshot: Option<String>,
    #[schemars(description = "Enable Iroh P2P networking.")]
    pub enable_iroh: Option<bool>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct VmIdParams {
    #[schemars(description = "UUID of the target VM.")]
    pub vm_id: String,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct ExecParams {
    #[schemars(description = "UUID of the target VM.")]
    pub vm_id: String,
    #[schemars(description = "Shell command to execute.")]
    pub command: String,
    #[schemars(description = "Timeout in ms (1000-300000). Default: 30000.")]
    pub timeout: Option<i64>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct CreateSnapshotParams {
    #[schemars(description = "UUID of the VM to snapshot.")]
    pub vm_id: String,
    #[schemars(description = "Unique name for this snapshot.")]
    pub name: String,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct SnapshotNameParams {
    #[schemars(description = "Snapshot name.")]
    pub name: String,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct DeliverMessageParams {
    #[schemars(description = "Target VM UUID.")]
    pub vm_id: String,
    #[schemars(description = "Source VM UUID or 'external'.")]
    pub from_vm_id: Option<String>,
    #[schemars(description = "Arbitrary JSON payload.")]
    pub payload: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct AwaitPtyParams {
    #[schemars(description = "UUID of the VM.")]
    pub vm_id: String,
    #[schemars(description = "Timeout in ms (>=1000). Default: 30000.")]
    pub timeout: Option<i64>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct EmptyParams {}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct SwitchProfileParams {
    #[schemars(description = "Profile name to switch to (e.g. 'cloud', 'local').")]
    pub profile: String,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct OpenTerminalParams {
    #[schemars(description = "UUID of the target VM.")]
    pub vm_id: String,
    #[schemars(description = "tmux session name (default: \"dev\").")]
    pub session_name: Option<String>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct TerminalReadParams {
    #[schemars(description = "UUID of the target VM.")]
    pub vm_id: String,
    #[schemars(description = "tmux session name (default: \"dev\").")]
    pub session_name: Option<String>,
    #[schemars(description = "Number of scrollback lines to capture (default: 100, max: 1000).")]
    pub scrollback_lines: Option<i32>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct TerminalSendParams {
    #[schemars(description = "UUID of the target VM.")]
    pub vm_id: String,
    #[schemars(description = "tmux session name (default: \"dev\").")]
    pub session_name: Option<String>,
    #[schemars(description = "Complete command to execute (Enter is appended automatically). Exactly one of 'command' or 'keys' must be provided.")]
    pub command: Option<String>,
    #[schemars(description = "Raw tmux key sequence (e.g., \"C-c\", \"Escape\"). Exactly one of 'command' or 'keys' must be provided.")]
    pub keys: Option<String>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct TerminalSendAndReadParams {
    #[schemars(description = "UUID of the target VM.")]
    pub vm_id: String,
    #[schemars(description = "tmux session name (default: \"dev\").")]
    pub session_name: Option<String>,
    #[schemars(description = "The command to execute (single-line only).")]
    pub command: String,
    #[schemars(description = "Timeout in milliseconds (default: 30000).")]
    pub timeout_ms: Option<i64>,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct TerminalListParams {
    #[schemars(description = "UUID of the target VM.")]
    pub vm_id: String,
}

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct TerminalCloseParams {
    #[schemars(description = "UUID of the target VM.")]
    pub vm_id: String,
    #[schemars(description = "Name of the tmux session to close.")]
    pub session_name: String,
}

// ── Helpers ──

fn mcp_err(msg: impl Into<String>) -> ErrorData {
    ErrorData::new(ErrorCode::INTERNAL_ERROR, msg.into(), None::<serde_json::Value>)
}

// ── Tool implementations ──

#[tool_router]
impl MjolnirMcpService {
    pub fn new(profile_name: String, api_base: String) -> Self {
        Self {
            tool_router: Self::tool_router(),
            api_base: Arc::new(RwLock::new(api_base)),
            profile_name: Arc::new(RwLock::new(profile_name)),
        }
    }

    fn current_api_base(&self) -> String {
        self.api_base.read().unwrap().clone()
    }

    /// Build an authenticated reqwest client.
    async fn authed_client(&self) -> Result<reqwest::Client, ErrorData> {
        let token = auth::load_token().await.ok_or_else(|| {
            mcp_err("Not logged in. Run `mjolnir login` to authenticate.")
        })?;

        let mut headers = reqwest::header::HeaderMap::new();
        let val = reqwest::header::HeaderValue::from_str(&format!("Bearer {}", token))
            .map_err(|e| mcp_err(format!("Invalid token: {}", e)))?;
        headers.insert(reqwest::header::AUTHORIZATION, val);

        reqwest::Client::builder()
            .default_headers(headers)
            .build()
            .map_err(|e| mcp_err(format!("HTTP client error: {}", e)))
    }

    /// GET request, return body text.
    async fn api_get(&self, path: &str) -> Result<CallToolResult, ErrorData> {
        let client = self.authed_client().await?;
        let url = format!("{}{}", self.current_api_base(), path);
        let resp = client.get(&url).send().await.map_err(|e| {
            mcp_err(format!("Request to {} failed: {}", url, e))
        })?;
        let status = resp.status();
        let body = resp.text().await.map_err(|e| {
            mcp_err(format!("Failed to read response: {}", e))
        })?;
        if status.is_success() {
            Ok(CallToolResult::success(vec![Content::text(body)]))
        } else {
            Ok(CallToolResult::error(vec![Content::text(format!("HTTP {} — {}", status, body))]))
        }
    }

    /// POST request with JSON body, return body text.
    async fn api_post(&self, path: &str, body: &serde_json::Value) -> Result<CallToolResult, ErrorData> {
        let client = self.authed_client().await?;
        let url = format!("{}{}", self.current_api_base(), path);
        let resp = client.post(&url).json(body).send().await.map_err(|e| {
            mcp_err(format!("Request to {} failed: {}", url, e))
        })?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| {
            mcp_err(format!("Failed to read response: {}", e))
        })?;
        if status.is_success() {
            Ok(CallToolResult::success(vec![Content::text(text)]))
        } else {
            Ok(CallToolResult::error(vec![Content::text(format!("HTTP {} — {}", status, text))]))
        }
    }

    /// DELETE request, return body text.
    async fn api_delete(&self, path: &str) -> Result<CallToolResult, ErrorData> {
        let client = self.authed_client().await?;
        let url = format!("{}{}", self.current_api_base(), path);
        let resp = client.delete(&url).send().await.map_err(|e| {
            mcp_err(format!("Request to {} failed: {}", url, e))
        })?;
        let status = resp.status();
        let text = resp.text().await.map_err(|e| {
            mcp_err(format!("Failed to read response: {}", e))
        })?;
        if status.is_success() {
            Ok(CallToolResult::success(vec![Content::text(text)]))
        } else {
            Ok(CallToolResult::error(vec![Content::text(format!("HTTP {} — {}", status, text))]))
        }
    }

    // ── Tools ──

    #[tool(name = "spawn_vm", description = "Create and boot a new microVM. Returns the VM's UUID and status.")]
    async fn spawn_vm(
        &self,
        Parameters(p): Parameters<SpawnVmParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let mut body = serde_json::Map::new();
        if let Some(v) = p.base_image {
            body.insert("base_image".into(), serde_json::Value::String(v));
        }
        if let Some(v) = p.memory_mb {
            body.insert("memory_mb".into(), serde_json::Value::Number(v.into()));
        }
        if let Some(v) = p.vcpus {
            body.insert("vcpus".into(), serde_json::Value::Number(v.into()));
        }
        if let Some(v) = p.ssh_public_key {
            body.insert("ssh_public_key".into(), serde_json::Value::String(v));
        }
        if let Some(v) = p.snapshot {
            body.insert("snapshot".into(), serde_json::Value::String(v));
        }
        if let Some(v) = p.enable_iroh {
            body.insert("enable_iroh".into(), serde_json::Value::Bool(v));
        }
        self.api_post("/api/vms", &serde_json::Value::Object(body)).await
    }

    #[tool(name = "list_vms", description = "List all running microVMs with state and connectivity info.")]
    async fn list_vms(
        &self,
        Parameters(_): Parameters<EmptyParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.api_get("/api/vms").await
    }

    #[tool(name = "get_vm", description = "Get detailed info about a specific VM.")]
    async fn get_vm(
        &self,
        Parameters(p): Parameters<VmIdParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.api_get(&format!("/api/vms/{}", p.vm_id)).await
    }

    #[tool(name = "exec", description = "Execute a shell command inside a running VM. Returns stdout, stderr, and exit code.")]
    async fn exec_cmd(
        &self,
        Parameters(p): Parameters<ExecParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let mut body = serde_json::json!({ "command": p.command });
        if let Some(t) = p.timeout {
            body["timeout"] = serde_json::Value::Number(t.into());
        }
        self.api_post(&format!("/api/vms/{}/exec", p.vm_id), &body).await
    }

    #[tool(name = "stop_vm", description = "Stop and destroy a running VM. Irreversible.")]
    async fn stop_vm(
        &self,
        Parameters(p): Parameters<VmIdParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.api_delete(&format!("/api/vms/{}", p.vm_id)).await
    }

    #[tool(name = "create_snapshot", description = "Snapshot a running VM's filesystem via BTRFS CoW.")]
    async fn create_snapshot(
        &self,
        Parameters(p): Parameters<CreateSnapshotParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let body = serde_json::json!({ "name": p.name });
        self.api_post(&format!("/api/vms/{}/snapshots", p.vm_id), &body).await
    }

    #[tool(name = "list_snapshots", description = "List all available snapshots.")]
    async fn list_snapshots(
        &self,
        Parameters(_): Parameters<EmptyParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.api_get("/api/snapshots").await
    }

    #[tool(name = "get_snapshot", description = "Get metadata for a specific snapshot.")]
    async fn get_snapshot(
        &self,
        Parameters(p): Parameters<SnapshotNameParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.api_get(&format!("/api/snapshots/{}", p.name)).await
    }

    #[tool(name = "delete_snapshot", description = "Permanently delete a snapshot.")]
    async fn delete_snapshot(
        &self,
        Parameters(p): Parameters<SnapshotNameParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.api_delete(&format!("/api/snapshots/{}", p.name)).await
    }

    #[tool(name = "deliver_message", description = "Send a message to a VM for inter-VM communication or coroutine wake-up.")]
    async fn deliver_message(
        &self,
        Parameters(p): Parameters<DeliverMessageParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let body = serde_json::json!({
            "from_vm_id": p.from_vm_id.unwrap_or_else(|| "external".into()),
            "payload": p.payload.unwrap_or(serde_json::Value::Object(Default::default())),
        });
        self.api_post(&format!("/api/vms/{}/messages", p.vm_id), &body).await
    }

    #[tool(name = "get_connection_ticket", description = "Get an Iroh connection ticket for P2P shell access.")]
    async fn get_connection_ticket(
        &self,
        Parameters(p): Parameters<VmIdParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.api_get(&format!("/api/vms/{}/ticket", p.vm_id)).await
    }

    #[tool(name = "list_dormant", description = "List VMs snapshotted and stopped, awaiting messages to restore.")]
    async fn list_dormant(
        &self,
        Parameters(_): Parameters<EmptyParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.api_get("/api/dormant").await
    }

    #[tool(name = "await_pty", description = "Wait for VM PTY/shell readiness. Returns connection ticket.")]
    async fn await_pty(
        &self,
        Parameters(p): Parameters<AwaitPtyParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let mut body = serde_json::json!({});
        if let Some(t) = p.timeout {
            body["timeout"] = serde_json::Value::Number(t.into());
        }
        self.api_post(&format!("/api/vms/{}/await-pty", p.vm_id), &body).await
    }

    #[tool(name = "open_terminal", description = "Open or attach to a persistent terminal session (tmux) inside a VM. Use this for interactive work that requires state across commands.")]
    async fn open_terminal(
        &self,
        Parameters(p): Parameters<OpenTerminalParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let session = p.session_name.as_deref().unwrap_or("dev");
        let body = serde_json::json!({ "session_name": session });
        self.api_post(&format!("/api/vms/{}/terminal/open", p.vm_id), &body).await
    }

    #[tool(name = "terminal_read", description = "Read the current visible content of a terminal session. Returns clean text with ANSI escapes stripped.")]
    async fn terminal_read(
        &self,
        Parameters(p): Parameters<TerminalReadParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let session = p.session_name.as_deref().unwrap_or("dev");
        let mut path = format!("/api/vms/{}/terminal/{}", p.vm_id, session);
        if let Some(lines) = p.scrollback_lines {
            path = format!("{}?scrollback_lines={}", path, lines);
        }
        self.api_get(&path).await
    }

    #[tool(name = "terminal_send", description = "Send a command or keystrokes to a terminal session. Use 'command' for complete commands or 'keys' for raw key sequences like 'C-c' or 'Escape'. Exactly one of 'command' or 'keys' must be provided.")]
    async fn terminal_send(
        &self,
        Parameters(p): Parameters<TerminalSendParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let session = p.session_name.as_deref().unwrap_or("dev");
        let mut body = serde_json::Map::new();
        if let Some(cmd) = p.command {
            body.insert("command".into(), serde_json::Value::String(cmd));
        }
        if let Some(keys) = p.keys {
            body.insert("keys".into(), serde_json::Value::String(keys));
        }
        self.api_post(
            &format!("/api/vms/{}/terminal/{}/send", p.vm_id, session),
            &serde_json::Value::Object(body),
        ).await
    }

    #[tool(name = "terminal_send_and_read", description = "Send a single-line command and wait for it to complete, returning the output. Preferred over separate send+read for simple command execution. Designed for single-line commands only; for multi-line scripts, write to a file first then execute it. Do NOT use for commands that spawn interactive processes (bash, python, ssh, docker exec -it, etc.) — these will timeout because no shell prompt returns.")]
    async fn terminal_send_and_read(
        &self,
        Parameters(p): Parameters<TerminalSendAndReadParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let session = p.session_name.as_deref().unwrap_or("dev");
        let mut body = serde_json::json!({ "command": p.command });
        if let Some(t) = p.timeout_ms {
            body["timeout_ms"] = serde_json::Value::Number(t.into());
        }
        self.api_post(
            &format!("/api/vms/{}/terminal/{}/send-and-read", p.vm_id, session),
            &body,
        ).await
    }

    #[tool(name = "terminal_list", description = "List active terminal sessions (tmux) in a VM.")]
    async fn terminal_list(
        &self,
        Parameters(p): Parameters<TerminalListParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.api_get(&format!("/api/vms/{}/terminal", p.vm_id)).await
    }

    #[tool(name = "terminal_close", description = "Close a terminal session in a VM. The session and its processes are destroyed.")]
    async fn terminal_close(
        &self,
        Parameters(p): Parameters<TerminalCloseParams>,
    ) -> Result<CallToolResult, ErrorData> {
        self.api_delete(&format!("/api/vms/{}/terminal/{}", p.vm_id, p.session_name)).await
    }

    #[tool(name = "get_profile", description = "Show which Mjolnir profile and API endpoint this MCP instance is currently using.")]
    async fn get_profile(
        &self,
        Parameters(_): Parameters<EmptyParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let profile = self.profile_name.read().unwrap().clone();
        let api = self.current_api_base();
        Ok(CallToolResult::success(vec![Content::text(
            serde_json::json!({ "profile": profile, "api": api }).to_string(),
        )]))
    }

    #[tool(name = "list_profiles", description = "List all configured Mjolnir profiles and their API endpoints.")]
    async fn list_profiles(
        &self,
        Parameters(_): Parameters<EmptyParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let profiles = config::load_profiles();
        let map: serde_json::Map<String, serde_json::Value> = profiles
            .profiles
            .into_iter()
            .map(|(name, p)| {
                let api = p.api.unwrap_or_else(|| "http://localhost:4000".into());
                (name, serde_json::Value::String(api))
            })
            .collect();
        Ok(CallToolResult::success(vec![Content::text(
            serde_json::Value::Object(map).to_string(),
        )]))
    }

    #[tool(name = "switch_profile", description = "Switch this MCP instance to a different profile/server. Affects only this Claude Code session — other sessions are unaffected.")]
    async fn switch_profile(
        &self,
        Parameters(p): Parameters<SwitchProfileParams>,
    ) -> Result<CallToolResult, ErrorData> {
        let profiles = config::load_profiles();
        let profile = profiles.profiles.get(&p.profile).cloned().ok_or_else(|| {
            let names: Vec<_> = profiles.profiles.keys().cloned().collect();
            mcp_err(format!(
                "Profile '{}' not found. Available: {}",
                p.profile,
                names.join(", ")
            ))
        })?;
        let new_api = profile.api.unwrap_or_else(|| "http://localhost:4000".into());
        *self.api_base.write().unwrap() = new_api.clone();
        *self.profile_name.write().unwrap() = p.profile.clone();
        Ok(CallToolResult::success(vec![Content::text(
            serde_json::json!({ "profile": p.profile, "api": new_api }).to_string(),
        )]))
    }
}

#[tool_handler]
impl ServerHandler for MjolnirMcpService {
    fn get_info(&self) -> ServerInfo {
        let mut info = ServerInfo::default();
        info.protocol_version = ProtocolVersion::V_2024_11_05;
        info.capabilities = ServerCapabilities::builder().enable_tools().build();
        info.server_info = Implementation::new("mjolnir", env!("CARGO_PKG_VERSION"));
        info.instructions = Some(
            "Mjolnir VM management — spawn, exec, snapshot, and manage Linux microVMs. \
             Use spawn_vm to create VMs, exec to run commands, and stop_vm to tear down."
                .into(),
        );
        info
    }
}

// ── Entry point ──

pub async fn run_mcp_server(
    profile_name: &str,
    profile: &config::Profile,
    api_flag: &Option<String>,
) -> anyhow::Result<()> {
    use rmcp::ServiceExt;

    let api_base = config::resolve_api(api_flag, profile)
        .trim_end_matches('/')
        .to_string();

    eprintln!("mjolnir mcp-serve: profile={} api={}", profile_name, api_base);

    let service = MjolnirMcpService::new(profile_name.to_string(), api_base);
    let server = service.serve(rmcp::transport::stdio()).await?;
    server.waiting().await?;
    Ok(())
}
