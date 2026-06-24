//! Mjolnir host-API data layer: typed response structs + authenticated HTTP
//! helpers. No printing, no CLI config/connect coupling — this is the reusable
//! core shared by the `mjolnir` CLI and external apps (Papyrus).

use anyhow::{Context, Result};
use serde::Deserialize;

// --- Response types ---

#[derive(Deserialize)]
#[allow(dead_code)]
pub struct SpawnResponse {
    pub id: String,
    pub state: String,
    pub ticket: Option<String>,
    #[serde(alias = "pty_ready")]
    pub shell_ready: Option<bool>,
    pub persist_interval_ms: Option<u64>,
}

#[derive(Deserialize)]
pub struct AwaitShellResponse {
    pub ticket: String,
}

#[derive(Deserialize)]
#[allow(dead_code)]
pub struct VmSummary {
    pub id: String,
    pub state: String,
    pub ticket: Option<String>,
    pub guest_ip: Option<String>,
    #[serde(alias = "pty_ready")]
    pub shell_ready: Option<bool>,
    pub web_url: Option<String>,
}

#[derive(Deserialize)]
pub struct ListResponse {
    pub vms: Vec<VmSummary>,
}

#[derive(Deserialize)]
pub struct VmConfig {
    pub vcpu_count: u32,
    pub mem_size_mib: u32,
    pub base_image: String,
    pub snapshot: Option<String>,
    pub rootfs_size_mb: Option<u32>,
}

#[derive(Deserialize)]
pub struct VmInfo {
    pub id: String,
    pub state: String,
    pub ticket: Option<String>,
    pub guest_ip: Option<String>,
    #[serde(alias = "pty_ready")]
    pub shell_ready: Option<bool>,
    pub web_url: Option<String>,
    pub config: Option<VmConfig>,
    pub boot_time: Option<i64>,
}

#[derive(Deserialize)]
pub struct SnapshotMetadata {
    pub name: String,
    pub source_vm_id: String,
    pub created_at: String,
    pub size_bytes: u64,
}

#[derive(Deserialize)]
pub struct SnapshotsResponse {
    pub snapshots: Vec<SnapshotMetadata>,
}

#[derive(Deserialize)]
pub struct SnapshotCreateResponse {
    pub name: String,
    pub source_vm_id: String,
    pub created_at: String,
    pub size_bytes: u64,
}

#[derive(Deserialize)]
pub struct HealthStatus {
    pub state: String,
    #[serde(default)]
    pub reason: Option<String>,
}

#[derive(Deserialize)]
pub struct HealthCheck {
    pub level: u32,
    pub name: String,
    pub status: HealthStatus,
    #[serde(default)]
    pub action: Option<String>,
}

#[derive(Deserialize)]
pub struct HealthReport {
    pub overall: String,
    pub checks: Vec<HealthCheck>,
}

#[derive(Deserialize)]
pub struct HostCheck {
    pub name: String,
    pub status: HealthStatus,
    #[serde(default)]
    pub detail: Option<String>,
}

#[derive(Deserialize)]
pub struct HostHealth {
    pub overall: String,
    pub checks: Vec<HostCheck>,
}

#[derive(Deserialize)]
pub struct TicketResponse {
    pub ticket: String,
}

#[derive(Deserialize)]
pub struct DormantEntry {
    pub vm_id: String,
    #[serde(default)]
    pub snapshot_name: Option<String>,
    #[serde(default)]
    pub dormant_since: Option<String>,
    #[serde(default)]
    pub pending_messages: Option<u32>,
}

#[derive(Deserialize)]
pub struct DormantResponse {
    pub dormant: Vec<DormantEntry>,
}

// --- Helpers ---

/// Send a request and return the raw response body as text, surfacing the
/// server's error body in the message on non-2xx (more useful than
/// `error_for_status`, which discards the body). Used by all commands that
/// support `--json` passthrough.
pub async fn send_text(req: reqwest::RequestBuilder, ctx: &str) -> Result<String> {
    let resp = req
        .send()
        .await
        .with_context(|| format!("{}: failed to send request", ctx))?;
    let status = resp.status();
    let body = resp
        .text()
        .await
        .with_context(|| format!("{}: failed to read response body", ctx))?;
    if !status.is_success() {
        anyhow::bail!("{}: server returned {} — {}", ctx, status, body.trim());
    }
    Ok(body)
}

/// Build an HTTP client with the resolved bearer token (explicit flag > env >
/// stored `~/.config/mjolnir/token.json`) applied as the `Authorization`
/// header. Passing `&None` rides whatever session the CLI established.
pub async fn api_client(token: &Option<String>) -> reqwest::Client {
    let effective = crate::auth::resolve_token(token).await;
    let mut headers = reqwest::header::HeaderMap::new();
    if let Some(t) = effective {
        if let Ok(val) = reqwest::header::HeaderValue::from_str(&format!("Bearer {}", t)) {
            headers.insert(reqwest::header::AUTHORIZATION, val);
        }
    }
    reqwest::Client::builder()
        .default_headers(headers)
        .build()
        .expect("failed to build HTTP client")
}

/// Fetch the VM list as typed data (no printing). The reusable core behind the
/// CLI's `list` command and external consumers' discovery.
pub async fn fetch_vms(client: &reqwest::Client, base: &str) -> Result<Vec<VmSummary>> {
    let resp: ListResponse = client
        .get(format!("{}/api/vms", base.trim_end_matches('/')))
        .send()
        .await
        .context("failed to fetch VM list")?
        .error_for_status()
        .context("VM list request failed")?
        .json()
        .await
        .context("failed to parse VM list response")?;
    Ok(resp.vms)
}

/// Resolve a VM identifier: if it looks like a UUID, use it directly.
/// Otherwise treat it as a ticket and look up the VM ID from the list.
pub async fn resolve_vm_id(
    client: &reqwest::Client,
    base: &str,
    id_or_ticket: &str,
) -> Result<String> {
    // UUIDs are 36 chars with hyphens
    if id_or_ticket.len() == 36 && id_or_ticket.contains('-') {
        return Ok(id_or_ticket.to_string());
    }
    // Look up by ticket
    let vms = fetch_vms(client, base).await?;
    vms.iter()
        .find(|vm| vm.ticket.as_deref() == Some(id_or_ticket))
        .map(|vm| vm.id.clone())
        .ok_or_else(|| anyhow::anyhow!("No VM found with ticket {}", id_or_ticket))
}
