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
    base_image: &Option<String>,
) -> Result<()> {
    if snapshot.is_some() && base_image.is_some() {
        anyhow::bail!("--snapshot and --base are mutually exclusive; pass at most one");
    }

    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    // Resolve the SSH public key from CLI config (a presentation/config
    // concern that stays in the bin; the lib's spawn_vm just takes the key).
    let ssh_public_key = crate::config::resolve_ssh_key_path().and_then(|key_path| {
        crate::config::read_ssh_public_key(profile).map(|ssh_key| {
            eprintln!("Using SSH key: {}", key_path);
            ssh_key
        })
    });
    if let Some(snap) = snapshot {
        eprintln!("Spawning from snapshot: {}", snap);
    }
    if let Some(img) = base_image {
        eprintln!("Spawning from base image: {}", img);
    }

    let opts = SpawnOptions {
        memory_mb: *memory_mb,
        snapshot: snapshot.clone(),
        base_image: base_image.clone(),
        ssh_public_key,
    };

    eprintln!("Spawning VM...");
    let resp = spawn_vm(&client, base, &opts).await?;

    // Print the VM id prominently and early: every follow-up verb (exec, kill,
    // info, snapshot) takes this id, not the ticket. Without it printed here,
    // the only way to find it again is `mj list`, and picking the wrong entry
    // out of that list is exactly how the wrong VM gets killed (mjolnir-aip).
    // Emitted on stderr so stdout keeps carrying only the ticket, unchanged,
    // for anything scripting off `mj spawn` output.
    eprintln!("\x1b[1;32mVM:\x1b[0m           {}", resp.id);

    // If shell not ready yet, await it.
    let ticket = if resp.shell_ready == Some(true) {
        resp.ticket.clone()
    } else {
        eprintln!("Waiting for shell...");
        Some(await_pty(&client, base, &resp.id, 30000).await?)
    };

    if let Some(ref t) = ticket {
        println!("{}", t);
    } else {
        eprintln!(
            "(no ticket yet — use `mj ticket get {}` once ready)",
            resp.id
        );
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

/// Turn repeated `--filter key=value` flags into `metadata.<key>=<value>` query
/// pairs for reqwest to encode.
///
/// A flag without `=`, or with an empty key, is a usage error rather than a
/// silently-ignored filter: quietly dropping a selector would widen a
/// destructive `mj list | xargs` pipeline instead of narrowing it.
fn metadata_query(filters: &[String]) -> Result<Vec<(String, String)>> {
    filters
        .iter()
        .map(|f| {
            let (key, value) = f
                .split_once('=')
                .with_context(|| format!("--filter must be key=value, got `{f}`"))?;
            if key.is_empty() {
                anyhow::bail!("--filter key cannot be empty (got `{f}`)");
            }
            Ok((format!("metadata.{key}"), value.to_string()))
        })
        .collect()
}

pub async fn cmd_list(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    dormant: bool,
    filters: &[String],
    json: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');
    let query = metadata_query(filters)?;

    let list_body = send_text(
        client.get(format!("{}/api/vms", base)).query(&query),
        "VM list",
    )
    .await?;
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
        let names = crate::domain::vm_app_names(profile, api_flag, token).await;
        println!(
            "{:<22} {:<10} {:<16} {:<6} {:<38} {}",
            "NAME", "STATE", "IP", "SHELL", "ID", "TICKET"
        );
        for vm in &resp.vms {
            println!(
                "{:<22} {:<10} {:<16} {:<6} {:<38} {}",
                names.get(&vm.id).map(String::as_str).unwrap_or("-"),
                vm.state,
                vm.guest_ip.as_deref().unwrap_or("-"),
                if vm.shell_ready == Some(true) {
                    "ready"
                } else {
                    "-"
                },
                vm.id,
                vm.ticket.as_deref().unwrap_or("-"),
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
        if let Some(bytes) = resp.rootfs_bytes {
            println!(
                "Disk Used:    {} (exclusive of shared base)",
                human_bytes(bytes)
            );
        }
    }

    if let Some(boot_time) = resp.boot_time {
        println!("\nTiming");
        println!("───────────────────────────────────────────────────────");
        println!("Boot Time:    {} (unix ms)", boot_time);
    }

    Ok(())
}

/// `mj storage` — whole-disk usage + per-area CoW-aware breakdown.
pub async fn cmd_storage(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    json: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let body = send_text(client.get(format!("{}/api/storage", base)), "storage").await?;
    if json {
        println!("{}", body);
        return Ok(());
    }
    let resp: StorageOverview =
        serde_json::from_str(&body).context("failed to parse storage response")?;

    if let Some(d) = &resp.disk {
        println!(
            "Disk:  {} used / {} total  ({:.1}% used, {} free)",
            human_bytes(d.used_bytes),
            human_bytes(d.total_bytes),
            d.use_percent,
            human_bytes(d.free_bytes)
        );
        println!();
    }
    println!(
        "{:<14} {:>7} {:>14} {:>14}",
        "AREA", "COUNT", "EXCLUSIVE", "LOGICAL"
    );
    for a in &resp.areas {
        let excl = a
            .exclusive_bytes
            .map(human_bytes)
            .unwrap_or_else(|| "-".into());
        let total = a.total_bytes.map(human_bytes).unwrap_or_else(|| "-".into());
        println!("{:<14} {:>7} {:>14} {:>14}", a.name, a.count, excl, total);
    }
    println!();
    println!("EXCLUSIVE = data unique to that area; LOGICAL counts CoW-shared blocks");
    println!("(pre-compression — physical disk use is the 'Disk' line above).");
    Ok(())
}

/// `mj trash list` — soft-deleted VMs still recoverable within the GC window.
pub async fn cmd_trash_list(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    json: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let body = send_text(client.get(format!("{}/api/trash", base)), "trash").await?;
    if json {
        println!("{}", body);
        return Ok(());
    }
    let resp: TrashResponse =
        serde_json::from_str(&body).context("failed to parse trash response")?;

    if resp.trash.is_empty() {
        eprintln!("Trash is empty.");
        return Ok(());
    }
    println!(
        "{:<38} {:>10} {:>12} {:>11}",
        "VM ID", "AGE", "REAPS IN", "RESTORABLE"
    );
    for e in &resp.trash {
        println!(
            "{:<38} {:>10} {:>12} {:>11}",
            e.vm_id,
            human_duration(e.age_seconds),
            human_duration(e.reaps_in_seconds),
            if e.restorable { "yes" } else { "no" }
        );
    }
    println!();
    println!("Undo a kill within the window:  mj trash restore <VM ID>");
    Ok(())
}

/// `mj trash restore <id>` — undo a kill: restore the rootfs and resume the VM.
pub async fn cmd_trash_restore(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    id: &str,
    json: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let body = send_text(
        client.post(format!("{}/api/trash/{}/restore", base, id)),
        "trash restore",
    )
    .await?;
    if json {
        println!("{}", body);
        return Ok(());
    }
    let resp: RestoreResponse =
        serde_json::from_str(&body).context("failed to parse restore response")?;

    if resp.resumed {
        println!("Restored {} — Reconcile is resuming it now.", resp.vm_id);
    } else {
        println!(
            "Restored {} rootfs (no saved config — re-spawn to start it).",
            resp.vm_id
        );
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

    // Echo exactly what is about to be destroyed, BEFORE destroying it — no
    // confirmation prompt (that would break scripted/`--all` use), just
    // visibility. Best-effort: a VM that's already gone or unreachable still
    // gets killed, it just prints with fewer details (mjolnir-aip).
    describe_kill_target(&client, base, &id).await;

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

/// Print what a kill is about to destroy: id, base_image/snapshot, and boot
/// time, pulled from the same `GET /api/vms/{id}` info endpoint `mj info`
/// uses. Failure to fetch info is non-fatal — the kill proceeds regardless,
/// just with a bare id line instead of full detail.
async fn describe_kill_target(client: &reqwest::Client, base: &str, id: &str) {
    match fetch_info(client, base, id).await {
        Ok(info) => {
            for line in kill_target_lines(&info) {
                eprintln!("{}", line);
            }
        }
        Err(_) => {
            eprintln!("Killing {} (could not fetch details)", id);
        }
    }
}

/// Pure formatting seam for [`describe_kill_target`]: turns a fetched
/// `VmInfo` into the lines to print before destroying it. Split out from the
/// network call so the formatting is unit-testable without a mock server.
fn kill_target_lines(info: &VmInfo) -> Vec<String> {
    let mut lines = vec![format!("Killing {}", info.id)];
    if let Some(cfg) = &info.config {
        match &cfg.snapshot {
            Some(snap) => lines.push(format!("  from snapshot:   {}", snap)),
            None => lines.push(format!("  from base image: {}", cfg.base_image)),
        }
    }
    if let Some(boot_time) = info.boot_time {
        // Milliseconds, not seconds: the server sets this with
        // System.system_time(:millisecond) (vm.ex:1033). Calling it a "unix
        // timestamp" unqualified invites someone to read it as seconds and
        // conclude the VM booted in 1970.
        lines.push(format!("  booted at:       {} (unix ms)", boot_time));
    }
    lines
}

/// Retire a stranded VM record to `:failed` so Reconcile stops trying to resume
/// it (`POST /api/vms/{id}/retire`). The rootfs subvolume is preserved — revive
/// it later with [`cmd_revive`]. See mjolnir-5fu.
pub async fn cmd_retire(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    id_or_ticket: &str,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let id = resolve_vm_id(&client, base, id_or_ticket).await?;

    send_text(
        client.post(format!("{}/api/vms/{}/retire", base, &id)),
        "retire",
    )
    .await?;

    eprintln!(
        "Retired {} (state=failed; rootfs preserved, revive to retry)",
        id
    );
    Ok(())
}

/// Revive a `:failed` record back to `:running` so the next Reconcile pass boots
/// it (`POST /api/vms/{id}/revive`). Clears the resume-failure counter.
pub async fn cmd_revive(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    id_or_ticket: &str,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let id = resolve_vm_id(&client, base, id_or_ticket).await?;

    send_text(
        client.post(format!("{}/api/vms/{}/revive", base, &id)),
        "revive",
    )
    .await?;

    eprintln!(
        "Revived {} (state=running; Reconcile will resume it shortly)",
        id
    );
    Ok(())
}

/// Reboot a running VM's guest in place and re-attach the control plane
/// (`POST /api/vms/{id}/reboot`). Recovery for a guest that is wedged while the
/// hypervisor still reports Running — e.g. after a snapshot pause/resume
/// (mjolnir-l4i). The server returns a non-2xx (surfaced here as an error) if
/// the guest does not answer after the reboot, so a failed recovery is loud.
pub async fn cmd_reboot(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    id_or_ticket: &str,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let id = resolve_vm_id(&client, base, id_or_ticket).await?;

    let body = send_text(
        client.post(format!("{}/api/vms/{}/reboot", base, &id)),
        "reboot",
    )
    .await?;

    let healthy = serde_json::from_str::<serde_json::Value>(&body)
        .ok()
        .and_then(|v| v.get("guest_healthy").and_then(|h| h.as_bool()))
        .unwrap_or(false);

    if healthy {
        eprintln!("Rebooted {} (guest healthy, control plane re-attached)", id);
    } else {
        eprintln!(
            "Rebooted {} (warning: guest did not answer after reboot)",
            id
        );
    }
    Ok(())
}

/// Permanently dispose of a stranded/`:failed` record: soft-delete its rootfs to
/// `@trash` and remove the record (`POST /api/vms/{id}/forget`). Recoverable
/// from `@trash` until reaped.
pub async fn cmd_forget(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    id_or_ticket: &str,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let id = resolve_vm_id(&client, base, id_or_ticket).await?;

    send_text(
        client.post(format!("{}/api/vms/{}/forget", base, &id)),
        "forget",
    )
    .await?;

    eprintln!(
        "Forgot {} (rootfs soft-deleted to @trash, record removed)",
        id
    );
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
        // Neither of these is a fault: the VM is doing something we asked, or
        // is still coming up. Rendering them as a bare "?" read as broken.
        "busy" => "\x1b[36mbusy\x1b[0m",
        "booting" => "\x1b[36mbooting\x1b[0m",
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

    // mjolnir-3v2: shown regardless of `overall` — a failed managed-secrets
    // unlock does not fail any check above (deliberately, to avoid driving
    // auto-heal), so this is the only place an operator running `mj doctor`
    // sees it.
    if let Some(f) = &report.secrets_unlock_failed {
        println!("───────────────────────────────────────────────────────");
        println!(
            "  \x1b[33msecrets unlock failed\x1b[0m  reason={}  at={}",
            f.reason, f.at
        );
        println!("  VM is running WITHOUT its managed secrets. Re-unlock deliberately.");
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

#[cfg(test)]
mod tests {
    use super::metadata_query;
    use super::{VmConfig, VmInfo};

    #[test]
    fn builds_prefixed_pairs_in_order() {
        let filters = vec!["app=buzz".to_string(), "id=aaa".to_string()];
        let got = metadata_query(&filters).unwrap();
        assert_eq!(
            got,
            vec![
                ("metadata.app".to_string(), "buzz".to_string()),
                ("metadata.id".to_string(), "aaa".to_string()),
            ]
        );
    }

    #[test]
    fn no_filters_is_an_empty_query_not_an_error() {
        assert!(metadata_query(&[]).unwrap().is_empty());
    }

    #[test]
    fn a_value_may_contain_equals_signs() {
        // Only the first `=` separates; base64-ish values survive intact.
        let got = metadata_query(&["k=a=b=c".to_string()]).unwrap();
        assert_eq!(got, vec![("metadata.k".to_string(), "a=b=c".to_string())]);
    }

    #[test]
    fn an_empty_value_is_allowed() {
        let got = metadata_query(&["k=".to_string()]).unwrap();
        assert_eq!(got, vec![("metadata.k".to_string(), String::new())]);
    }

    #[test]
    fn a_malformed_filter_is_an_error_not_a_dropped_selector() {
        // Silently ignoring this would WIDEN a `mj list --filter ... | xargs mj kill`
        // pipeline from "my VMs" to "every VM". Fail loudly.
        assert!(metadata_query(&["nokey".to_string()]).is_err());
        assert!(metadata_query(&["=value".to_string()]).is_err());
    }

    #[tokio::test]
    async fn spawn_rejects_both_snapshot_and_base_before_touching_the_network() {
        // --snapshot and --base name disjoint namespaces (@snapshots/ vs @base/);
        // silently preferring one would spawn from the wrong image. This must
        // fail fast, before any client/API resolution — no server needed to
        // exercise it. clap's `conflicts_with` also catches this at parse time,
        // but cmd_spawn is a public fn other callers (tests, MCP, etc.) can
        // invoke directly, so it needs to guard itself too.
        let profile = crate::config::Profile::default();
        let result = super::cmd_spawn(
            &profile,
            &None,
            &None,
            false,
            &None,
            &Some("my-snapshot".to_string()),
            &Some("my-base-image".to_string()),
        )
        .await;
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("mutually exclusive"));
    }

    fn sample_vm_info(config: Option<VmConfig>, boot_time: Option<i64>) -> VmInfo {
        VmInfo {
            id: "3f9e2b1c-0000-0000-0000-000000000001".to_string(),
            state: "running".to_string(),
            ticket: None,
            guest_ip: None,
            shell_ready: None,
            web_url: None,
            iroh_node_id: None,
            config,
            boot_time,
            rootfs_bytes: None,
        }
    }

    #[test]
    fn kill_target_lines_shows_snapshot_when_spawned_from_one() {
        let info = sample_vm_info(
            Some(VmConfig {
                vcpu_count: 2,
                mem_size_mib: 512,
                base_image: "arch".to_string(),
                snapshot: Some("nightly-2026-08-11".to_string()),
                rootfs_size_mb: None,
            }),
            Some(1_755_000_000),
        );
        let lines = super::kill_target_lines(&info);
        assert_eq!(lines[0], "Killing 3f9e2b1c-0000-0000-0000-000000000001");
        assert!(lines
            .iter()
            .any(|l| l.contains("from snapshot:") && l.contains("nightly-2026-08-11")));
        assert!(!lines.iter().any(|l| l.contains("from base image:")));
        assert!(lines.iter().any(|l| l.contains("booted at:")));
    }

    #[test]
    fn kill_target_lines_shows_base_image_when_no_snapshot() {
        let info = sample_vm_info(
            Some(VmConfig {
                vcpu_count: 2,
                mem_size_mib: 512,
                base_image: "ubuntu-24.04".to_string(),
                snapshot: None,
                rootfs_size_mb: None,
            }),
            None,
        );
        let lines = super::kill_target_lines(&info);
        assert!(lines
            .iter()
            .any(|l| l.contains("from base image:") && l.contains("ubuntu-24.04")));
        assert!(!lines.iter().any(|l| l.contains("from snapshot:")));
        assert!(!lines.iter().any(|l| l.contains("boot time:")));
    }

    #[test]
    fn kill_target_lines_degrades_to_bare_id_when_config_unknown() {
        // fetch_info can succeed but return a VM record with no config (e.g.
        // mid-boot); the id line must still be present and nothing panics on
        // the missing fields.
        let info = sample_vm_info(None, None);
        let lines = super::kill_target_lines(&info);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0], "Killing 3f9e2b1c-0000-0000-0000-000000000001");
    }
}
