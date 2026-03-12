//! API command implementations and response types.

use anyhow::{Context, Result};
use serde::Deserialize;

use crate::config::Profile;

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
struct ExecResponse {
    output: Option<String>,
    exit_code: Option<i32>,
    stderr: Option<String>,
}

// --- Helpers ---

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
    let resp: ListResponse = client
        .get(format!("{}/api/vms", base))
        .send()
        .await
        .context("failed to fetch VM list")?
        .error_for_status()
        .context("VM list request failed")?
        .json()
        .await
        .context("failed to parse VM list response")?;

    resp.vms
        .iter()
        .find(|vm| vm.ticket.as_deref() == Some(id_or_ticket))
        .map(|vm| vm.id.clone())
        .ok_or_else(|| anyhow::anyhow!("No VM found with ticket {}", id_or_ticket))
}

// --- API commands ---

pub async fn cmd_spawn(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    connect: bool,
    memory_mb: &Option<u32>,
    snapshot: &Option<String>,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    // Include SSH public key if available
    let mut body = serde_json::json!({});
    if let Some(key_path) = crate::config::resolve_ssh_key_path() {
        if let Some(ssh_key) = crate::config::read_ssh_public_key(profile) {
            eprintln!("Using SSH key: {}", key_path);
            body["ssh_public_key"] = serde_json::Value::String(ssh_key);
        }
    }

    // Include memory override if specified
    if let Some(memory) = memory_mb {
        body["memory_mb"] = serde_json::Value::Number((*memory).into());
    }

    // Include snapshot if specified
    if let Some(snap) = snapshot {
        eprintln!("Spawning from snapshot: {}", snap);
        body["snapshot"] = serde_json::Value::String(snap.clone());
    }

    eprintln!("Spawning VM...");
    let resp: SpawnResponse = client
        .post(format!("{}/api/vms", base))
        .json(&body)
        .send()
        .await
        .context("failed to send spawn request")?
        .error_for_status()
        .context("spawn request failed")?
        .json()
        .await
        .context("failed to parse spawn response")?;

    // If shell not ready yet, await it
    let ticket = if resp.shell_ready == Some(true) {
        resp.ticket.clone()
    } else {
        eprintln!("Waiting for shell...");
        let await_resp: AwaitShellResponse = client
            .post(format!("{}/api/vms/{}/await-pty", base, resp.id))
            .json(&serde_json::json!({"timeout": 30000}))
            .send()
            .await
            .context("failed to send await-pty request")?
            .error_for_status()
            .context("await-pty request failed")?
            .json()
            .await
            .context("failed to parse await-pty response")?;
        Some(await_resp.ticket)
    };

    if let Some(ref t) = ticket {
        println!("{}", t);
    } else {
        eprintln!("VM {} (no ticket yet)", resp.id);
    }

    // Show persist interval so users know their worst-case backup window
    match resp.persist_interval_ms {
        Some(0) => eprintln!("\x1b[36m⚡ Persist: instant (every change)\x1b[0m"),
        Some(ms) => eprintln!("\x1b[36m💾 Persist interval: {}ms\x1b[0m", ms),
        None => {}
    }

    if connect {
        let ticket_str = ticket.ok_or_else(|| anyhow::anyhow!("No ticket available"))?;
        let addr = crate::connect::resolve_addr(&ticket_str, None, &[])?;
        crate::connect::connect_to_vm(addr, None).await?;
    }

    Ok(())
}

pub async fn cmd_list(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let resp: ListResponse = client
        .get(format!("{}/api/vms", base))
        .send()
        .await
        .context("failed to fetch VM list")?
        .error_for_status()
        .context("VM list request failed")?
        .json()
        .await
        .context("failed to parse VM list response")?;

    if resp.vms.is_empty() {
        eprintln!("No VMs running.");
        return Ok(());
    }

    // Header
    println!(
        "{:<54} {:<10} {:<16} {:<6} {}",
        "TICKET", "STATE", "IP", "SHELL", "ID"
    );

    for vm in &resp.vms {
        println!(
            "{:<54} {:<10} {:<16} {:<6} {}",
            vm.ticket.as_deref().unwrap_or("-"),
            vm.state,
            vm.guest_ip.as_deref().unwrap_or("-"),
            if vm.shell_ready == Some(true) {
                "ready"
            } else {
                "-"
            },
            vm.id,
        );
    }

    Ok(())
}

pub async fn cmd_info(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    id_or_ticket: &str,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let id = resolve_vm_id(&client, base, id_or_ticket).await?;

    let resp: VmInfo = client
        .get(format!("{}/api/vms/{}", base, &id))
        .send()
        .await
        .context("failed to fetch VM info")?
        .error_for_status()
        .context("VM info request failed")?
        .json()
        .await
        .context("failed to parse VM info response")?;

    println!("VM Information");
    println!("═══════════════════════════════════════════════════════");
    println!("ID:           {}", resp.id);
    println!("State:        {}", resp.state);
    println!(
        "Shell Ready:  {}",
        if resp.shell_ready == Some(true) {
            "yes"
        } else {
            "no"
        }
    );

    if let Some(ip) = resp.guest_ip {
        println!("Guest IP:     {}", ip);
    }

    if let Some(ref ticket) = resp.ticket {
        println!("\nConnection");
        println!("───────────────────────────────────────────────────────");
        println!("Ticket:       {}", ticket);
        if let Some(ref url) = resp.web_url {
            println!("Web URL:      {}", url);
        }
    }

    if let Some(config) = resp.config {
        println!("\nResources");
        println!("───────────────────────────────────────────────────────");
        println!("vCPUs:        {}", config.vcpu_count);
        println!("Memory:       {} MiB", config.mem_size_mib);
        println!("Base Image:   {}", config.base_image);
        if let Some(snapshot) = config.snapshot {
            println!("Snapshot:     {}", snapshot);
        }
        if let Some(size) = config.rootfs_size_mb {
            println!("Rootfs Size:  {} MiB", size);
        }
    }

    if let Some(boot_time) = resp.boot_time {
        println!("\nTiming");
        println!("───────────────────────────────────────────────────────");
        println!("Boot Time:    {} (unix timestamp)", boot_time);
    }

    Ok(())
}

pub async fn cmd_kill(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    id_or_ticket: &str,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let id = resolve_vm_id(&client, base, id_or_ticket).await?;

    client
        .delete(format!("{}/api/vms/{}", base, &id))
        .send()
        .await
        .context("failed to send kill request")?
        .error_for_status()
        .context("kill request failed")?;

    eprintln!("Killed {}", id);
    Ok(())
}

pub async fn cmd_snapshot(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    id_or_ticket: &str,
    name: &str,
    compact: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let id = resolve_vm_id(&client, base, id_or_ticket).await?;

    eprintln!(
        "Creating snapshot '{}'{}...",
        name,
        if compact { " (compact)" } else { "" }
    );

    let mut body = serde_json::json!({
        "name": name
    });
    if compact {
        body["compact"] = serde_json::Value::Bool(true);
    }

    let resp: SnapshotCreateResponse = client
        .post(format!("{}/api/vms/{}/snapshots", base, &id))
        .json(&body)
        .send()
        .await
        .context("failed to send snapshot request")?
        .error_for_status()
        .context("snapshot request failed")?
        .json()
        .await
        .context("failed to parse snapshot response")?;

    let size_mb = resp.size_bytes / 1024 / 1024;
    eprintln!("Snapshot '{}' created successfully", resp.name);
    eprintln!("  Size: {} MB", size_mb);
    eprintln!("  Source VM: {}", resp.source_vm_id);
    eprintln!("  Created: {}", resp.created_at);

    Ok(())
}

pub async fn cmd_snapshots(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let resp: SnapshotsResponse = client
        .get(format!("{}/api/snapshots", base))
        .send()
        .await
        .context("failed to fetch snapshots")?
        .error_for_status()
        .context("snapshots request failed")?
        .json()
        .await
        .context("failed to parse snapshots response")?;

    if resp.snapshots.is_empty() {
        eprintln!("No snapshots found.");
        return Ok(());
    }

    // Header
    println!(
        "{:<30} {:<38} {:<28} {:>12}",
        "NAME", "SOURCE VM", "CREATED AT", "SIZE"
    );

    for snap in &resp.snapshots {
        let size_mb = snap.size_bytes / 1024 / 1024;
        println!(
            "{:<30} {:<38} {:<28} {:>9} MB",
            snap.name, snap.source_vm_id, snap.created_at, size_mb
        );
    }

    Ok(())
}

pub async fn cmd_url(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    id_or_ticket: &str,
    port: Option<u16>,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let id = resolve_vm_id(&client, base, id_or_ticket).await?;

    let resp: VmInfo = client
        .get(format!("{}/api/vms/{}", base, &id))
        .send()
        .await
        .context("failed to fetch VM info")?
        .error_for_status()
        .context("VM info request failed")?
        .json()
        .await
        .context("failed to parse VM info response")?;

    match resp.web_url {
        Some(url) => {
            if let Some(p) = port {
                // Insert port suffix before the domain: https://<ticket>-<port>.<domain>
                // The web_url is https://<ticket>.<domain>, so insert -<port> before the first dot
                if let Some(dot_pos) = url.find('.') {
                    println!("{}-{}{}", &url[..dot_pos], p, &url[dot_pos..]);
                } else {
                    println!("{}", url);
                }
            } else {
                println!("{}", url);
            }
        }
        None => {
            anyhow::bail!("VM {} does not have Iroh enabled (no web URL available)", id);
        }
    }

    Ok(())
}

pub async fn cmd_exec(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    id_or_ticket: &str,
    cmd: &str,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let id = resolve_vm_id(&client, base, id_or_ticket)
        .await
        .context("failed to resolve VM ID")?;

    let resp: ExecResponse = client
        .post(format!("{}/api/vms/{}/exec", base, &id))
        .json(&serde_json::json!({ "command": cmd }))
        .send()
        .await
        .context("failed to send exec request")?
        .error_for_status()
        .context("exec request failed")?
        .json()
        .await
        .context("failed to parse exec response")?;

    if let Some(output) = resp.output {
        print!("{}", output);
        return Ok(());
    }

    if let Some(code) = resp.exit_code {
        if let Some(stderr) = resp.stderr {
            eprint!("{}", stderr);
        }
        std::process::exit(code);
    }

    Ok(())
}
