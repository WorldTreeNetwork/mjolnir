//! CLI command implementations (presentation layer).
//!
//! The typed response structs + authenticated HTTP helpers now live in the
//! shared `mjolnir-api` crate (`mjolnir_api::api`); this module keeps the
//! CLI-facing `cmd_*` functions that format output and depend on CLI config /
//! connect machinery. The glob re-export below also preserves existing
//! `crate::api::*` paths (e.g. `crate::api::api_client` used by forge).

use anyhow::{Context, Result};
use serde::Deserialize;

pub use mjolnir_api::api::*;

use crate::config::Profile;

// CLI-only response shape (not part of the shared data layer).
#[derive(Deserialize)]
struct ExecResponse {
    output: Option<String>,
    exit_code: Option<i32>,
    stderr: Option<String>,
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
    dormant: bool,
    json: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let list_body = send_text(client.get(format!("{}/api/vms", base)), "VM list").await?;
    let dormant_body = if dormant {
        Some(send_text(client.get(format!("{}/api/dormant", base)), "dormant list").await?)
    } else {
        None
    };

    if json {
        match &dormant_body {
            Some(d) => {
                let combined = serde_json::json!({
                    "vms": serde_json::from_str::<serde_json::Value>(&list_body)?,
                    "dormant": serde_json::from_str::<serde_json::Value>(d)?,
                });
                println!("{}", serde_json::to_string_pretty(&combined)?);
            }
            None => println!("{}", list_body),
        }
        return Ok(());
    }

    let resp: ListResponse =
        serde_json::from_str(&list_body).context("failed to parse VM list response")?;

    if resp.vms.is_empty() {
        eprintln!("No VMs running.");
    } else {
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
    }

    if let Some(d) = dormant_body {
        let dorm: DormantResponse =
            serde_json::from_str(&d).context("failed to parse dormant list response")?;
        if dorm.dormant.is_empty() {
            eprintln!("\nNo dormant VMs.");
        } else {
            println!(
                "\n{:<38} {:<24} {:<10} {}",
                "ID", "SNAPSHOT", "MESSAGES", "DORMANT SINCE"
            );
            for e in &dorm.dormant {
                println!(
                    "{:<38} {:<24} {:<10} {}",
                    e.vm_id,
                    e.snapshot_name.as_deref().unwrap_or("-"),
                    e.pending_messages.unwrap_or(0),
                    e.dormant_since.as_deref().unwrap_or("-"),
                );
            }
        }
    }

    Ok(())
}

/// Stop and destroy every running VM.
pub async fn cmd_kill_all(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let vms = fetch_vms(&client, base).await?;

    if vms.is_empty() {
        eprintln!("No VMs running.");
        return Ok(());
    }

    for vm in &vms {
        send_text(client.delete(format!("{}/api/vms/{}", base, vm.id)), "kill").await?;
        eprintln!("Killed {}", vm.id);
    }

    Ok(())
}

pub async fn cmd_info(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    id_or_ticket: &str,
    json: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let id = resolve_vm_id(&client, base, id_or_ticket).await?;

    let body = send_text(client.get(format!("{}/api/vms/{}", base, &id)), "VM info").await?;
    if json {
        println!("{}", body);
        return Ok(());
    }
    let resp: VmInfo = serde_json::from_str(&body).context("failed to parse VM info response")?;

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

pub async fn cmd_snapshot_create(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    id_or_ticket: &str,
    name: &str,
    compact: bool,
    json: bool,
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

    let resp_body = send_text(
        client
            .post(format!("{}/api/vms/{}/snapshots", base, &id))
            .json(&body),
        "snapshot create",
    )
    .await?;
    if json {
        println!("{}", resp_body);
        return Ok(());
    }
    let resp: SnapshotCreateResponse =
        serde_json::from_str(&resp_body).context("failed to parse snapshot response")?;

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
    json: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let body = send_text(client.get(format!("{}/api/snapshots", base)), "snapshots").await?;
    if json {
        println!("{}", body);
        return Ok(());
    }
    let resp: SnapshotsResponse =
        serde_json::from_str(&body).context("failed to parse snapshots response")?;

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

pub async fn cmd_snapshot_show(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    name: &str,
    json: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let body = send_text(
        client.get(format!("{}/api/snapshots/{}", base, name)),
        "snapshot",
    )
    .await?;
    if json {
        println!("{}", body);
        return Ok(());
    }
    let m: SnapshotMetadata =
        serde_json::from_str(&body).context("failed to parse snapshot response")?;
    let size_mb = m.size_bytes / 1024 / 1024;
    println!("Snapshot");
    println!("═══════════════════════════════════════════════════════");
    println!("Name:         {}", m.name);
    println!("Source VM:    {}", m.source_vm_id);
    println!("Created At:    {}", m.created_at);
    println!("Size:         {} MB", size_mb);
    Ok(())
}

pub async fn cmd_snapshot_rm(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    name: &str,
    json: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let body = send_text(
        client.delete(format!("{}/api/snapshots/{}", base, name)),
        "snapshot delete",
    )
    .await?;
    if json {
        println!("{}", body);
    } else {
        eprintln!("Deleted snapshot {}", name);
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
            anyhow::bail!(
                "VM {} does not have Iroh enabled (no web URL available)",
                id
            );
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

// --- Health / doctor ---

fn paint_state(state: &str) -> &'static str {
    match state {
        "ok" => "\x1b[32mok\x1b[0m",
        "degraded" => "\x1b[33mdegraded\x1b[0m",
        "dead" => "\x1b[31mdead\x1b[0m",
        _ => "\x1b[90m?\x1b[0m",
    }
}

/// `mj doctor <id>` — probe a VM's health ladder (L0..); with `--fix`, heal
/// degraded/dead checks up to `max_level` (default 2). Read-only without --fix.
/// Exits non-zero if the VM is not fully healthy after the run.
pub async fn cmd_doctor(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    id_or_ticket: &str,
    fix: bool,
    max_level: Option<u32>,
    json: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let id = resolve_vm_id(&client, base, id_or_ticket).await?;

    let body = if fix {
        send_text(
            client
                .post(format!("{}/api/vms/{}/heal", base, &id))
                .json(&serde_json::json!({ "max_level": max_level.unwrap_or(2) })),
            "heal",
        )
        .await?
    } else {
        send_text(
            client.get(format!("{}/api/vms/{}/health", base, &id)),
            "health",
        )
        .await?
    };

    if json {
        println!("{}", body);
        let report: HealthReport = serde_json::from_str(&body)?;
        if report.overall != "ok" {
            std::process::exit(1);
        }
        return Ok(());
    }

    let report: HealthReport =
        serde_json::from_str(&body).context("failed to parse health report")?;

    println!("VM {}  —  {}", id, paint_state(&report.overall));
    println!("───────────────────────────────────────────────────────");
    for c in &report.checks {
        let mut line = format!(
            "  L{} {:<20} {}",
            c.level,
            c.name,
            paint_state(&c.status.state)
        );
        if let Some(r) = &c.status.reason {
            line.push_str(&format!("  ({})", r));
        }
        if let Some(a) = &c.action {
            line.push_str(&format!("  → {}", a));
        }
        println!("{}", line);
    }

    if report.overall != "ok" {
        std::process::exit(1);
    }
    Ok(())
}

/// `mj doctor` (no id) — check API reachability + host health (KVM, vsock,
/// IP forwarding, BTRFS mount, ...); with `--fix`, run the host heal.
pub async fn cmd_doctor_host(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    fix: bool,
    json: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let api_body = send_text(client.get(format!("{}/api/health", base)), "API health").await?;
    let host_body = if fix {
        send_text(
            client.post(format!("{}/api/health/host/heal", base)),
            "host heal",
        )
        .await?
    } else {
        send_text(
            client.get(format!("{}/api/health/host", base)),
            "host health",
        )
        .await?
    };

    if json {
        let combined = serde_json::json!({
            "api": serde_json::from_str::<serde_json::Value>(&api_body)?,
            "host": serde_json::from_str::<serde_json::Value>(&host_body)?,
        });
        println!("{}", serde_json::to_string_pretty(&combined)?);
        let host: HostHealth = serde_json::from_str(&host_body)?;
        if host.overall != "ok" {
            std::process::exit(1);
        }
        return Ok(());
    }

    let host: HostHealth =
        serde_json::from_str(&host_body).context("failed to parse host health")?;

    println!("API {}  —  reachable ({})", paint_state("ok"), base);
    println!("Host  —  {}", paint_state(&host.overall));
    println!("───────────────────────────────────────────────────────");
    for c in &host.checks {
        let mut line = format!("  {:<24} {}", c.name, paint_state(&c.status.state));
        if let Some(d) = &c.detail {
            line.push_str(&format!("  ({})", d));
        }
        if let Some(r) = &c.status.reason {
            line.push_str(&format!("  ({})", r));
        }
        println!("{}", line);
    }

    if host.overall != "ok" {
        std::process::exit(1);
    }
    Ok(())
}

/// `mj message <id> <json>` — deliver a JSON payload into a VM; wakes a
/// dormant VM if it is parked.
pub async fn cmd_message(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    id_or_ticket: &str,
    payload: &str,
    json: bool,
) -> Result<()> {
    let payload_value: serde_json::Value =
        serde_json::from_str(payload).context("payload must be valid JSON")?;

    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let id = resolve_vm_id(&client, base, id_or_ticket).await?;

    let body = send_text(
        client
            .post(format!("{}/api/vms/{}/messages", base, &id))
            .json(&serde_json::json!({ "payload": payload_value })),
        "message",
    )
    .await?;

    if json {
        println!("{}", body);
    } else {
        eprintln!("Delivered message to {}", id);
    }
    Ok(())
}

/// `mj ticket get <id>` — fetch a VM's connection ticket; with `--wait`,
/// block until the PTY is ready first (the await-pty path).
pub async fn cmd_ticket_get(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    id_or_ticket: &str,
    wait: bool,
    timeout: Option<u64>,
    json: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let id = resolve_vm_id(&client, base, id_or_ticket).await?;

    let body = if wait {
        send_text(
            client
                .post(format!("{}/api/vms/{}/await-pty", base, &id))
                .json(&serde_json::json!({ "timeout": timeout.unwrap_or(30000) })),
            "await-pty",
        )
        .await?
    } else {
        send_text(
            client.get(format!("{}/api/vms/{}/ticket", base, &id)),
            "ticket",
        )
        .await?
    };

    if json {
        println!("{}", body);
        return Ok(());
    }
    let tr: TicketResponse =
        serde_json::from_str(&body).context("failed to parse ticket response")?;
    println!("{}", tr.ticket);
    Ok(())
}
