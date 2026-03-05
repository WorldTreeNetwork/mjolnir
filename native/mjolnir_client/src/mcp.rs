//! MCP (Model Context Protocol) server for Mjolnir VM management.
//!
//! Runs over stdio, proxying authenticated HTTP requests to the remote
//! Mjolnir API. Reuses the CLI's config and auth modules.
//!
//! Usage:
//!   mjolnir mcp-serve              # uses default profile
//!   mjolnir mcp-serve --api http://localhost:4000

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
    api_base: String,
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

// ── Helpers ──

fn mcp_err(msg: impl Into<String>) -> ErrorData {
    ErrorData::new(ErrorCode::INTERNAL_ERROR, msg.into(), None::<serde_json::Value>)
}

// ── Tool implementations ──

#[tool_router]
impl MjolnirMcpService {
    pub fn new(api_base: String) -> Self {
        Self {
            tool_router: Self::tool_router(),
            api_base,
        }
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
        let url = format!("{}{}", self.api_base, path);
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
        let url = format!("{}{}", self.api_base, path);
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
        let url = format!("{}{}", self.api_base, path);
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
    profile: &config::Profile,
    api_flag: &Option<String>,
) -> anyhow::Result<()> {
    use rmcp::ServiceExt;

    let api_base = config::resolve_api(api_flag, profile)
        .trim_end_matches('/')
        .to_string();

    eprintln!("mjolnir mcp-serve: connecting to {}", api_base);

    let service = MjolnirMcpService::new(api_base);
    let server = service.serve(rmcp::transport::stdio()).await?;
    server.waiting().await?;
    Ok(())
}
