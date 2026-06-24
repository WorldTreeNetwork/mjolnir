//! Forge subcommand — host config reconciler.
//!
//! Drives the Forge HTTP API at /api/forge/* over an SSH-tunneled connection.

use anyhow::{Context, Result};
use serde::Deserialize;
use std::io::Write;
use std::time::Duration;

use crate::config::Profile;

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
#[allow(dead_code)]
pub struct HostInfo {
    pub host: String,
    pub running: bool,
    pub declared: bool,
}

#[derive(Deserialize)]
#[allow(dead_code)]
pub struct HostsResponse {
    pub hosts: Vec<HostInfo>,
}

#[derive(Deserialize)]
#[allow(dead_code)]
pub struct PlanEntry {
    pub kind: String,
    pub id: String,
    pub status: String,
    pub declared_hash: Option<String>,
    pub owned_hash: Option<String>,
    pub observed_hash: Option<String>,
}

#[derive(Deserialize)]
#[allow(dead_code)]
pub struct PlanResponse {
    pub host: String,
    pub entries: Vec<PlanEntry>,
}

#[derive(Deserialize)]
#[allow(dead_code)]
pub struct ApplyResult {
    pub kind: String,
    pub id: String,
    pub result: String,
    pub reason: Option<String>,
}

#[derive(Deserialize)]
#[allow(dead_code)]
pub struct ApplyResponse {
    pub host: String,
    pub results: Vec<ApplyResult>,
}

#[derive(Deserialize)]
#[allow(dead_code)]
pub struct StateRecord {
    pub host: String,
    pub kind: String,
    pub resource_id: String,
    pub status: String,
    pub declared_hash: Option<String>,
    pub owned_hash: Option<String>,
    pub observed_hash: Option<String>,
    pub applied_at: Option<String>,
    pub observed_at: Option<String>,
    pub updated_at: Option<String>,
}

#[derive(Deserialize)]
#[allow(dead_code)]
pub struct StateResponse {
    pub records: Vec<StateRecord>,
}

// ---------------------------------------------------------------------------
// ANSI color helpers
// ---------------------------------------------------------------------------

fn color_for_status(status: &str) -> &'static str {
    match status {
        "converged" => "\x1b[32m",                             // green
        "drifted" | "missing" | "new" | "prune" => "\x1b[33m", // yellow
        "conflict" => "\x1b[31m",                              // red
        "unmanaged" => "\x1b[34m",                             // blue
        "tombstone" | "ignored" => "\x1b[2m",                  // dim
        _ => "\x1b[0m",
    }
}

const RESET: &str = "\x1b[0m";
const GREEN: &str = "\x1b[32m";
const RED: &str = "\x1b[31m";

fn hash_prefix(h: &Option<String>) -> String {
    h.as_deref()
        .map(|s| s.get(..8).unwrap_or(s).to_string())
        .unwrap_or_else(|| "-".to_string())
}

// ---------------------------------------------------------------------------
// hosts list
// ---------------------------------------------------------------------------

pub async fn hosts_list(
    api: Option<String>,
    token: Option<String>,
    profile: &Profile,
) -> Result<()> {
    let client = crate::api::api_client(&token).await;
    let base = crate::config::resolve_api(&api, profile);
    let base = base.trim_end_matches('/');

    let resp: HostsResponse = client
        .get(format!("{}/api/forge/hosts", base))
        .send()
        .await
        .context("failed to fetch forge hosts")?
        .error_for_status()
        .context("forge hosts request failed")?
        .json()
        .await
        .context("failed to parse forge hosts response")?;

    if resp.hosts.is_empty() {
        eprintln!("No forge hosts registered.");
        return Ok(());
    }

    println!("{:<30} {:<10} {:<10}", "HOST", "RUNNING", "DECLARED");
    for h in &resp.hosts {
        println!(
            "{:<30} {:<10} {:<10}",
            h.host,
            if h.running { "yes" } else { "no" },
            if h.declared { "yes" } else { "no" },
        );
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// hosts add
// ---------------------------------------------------------------------------

pub async fn hosts_add(
    api: Option<String>,
    token: Option<String>,
    host: String,
    transport: String,
    profile: &Profile,
) -> Result<()> {
    let client = crate::api::api_client(&token).await;
    let base = crate::config::resolve_api(&api, profile);
    let base = base.trim_end_matches('/');

    let body = serde_json::json!({ "host": host, "transport": transport });

    let resp = client
        .post(format!("{}/api/forge/hosts", base))
        .json(&body)
        .send()
        .await
        .context("failed to send forge hosts add request")?
        .error_for_status()
        .context("forge hosts add request failed")?
        .json::<serde_json::Value>()
        .await
        .context("failed to parse forge hosts add response")?;

    let status = resp
        .get("status")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown");

    println!("Host {}: {}", host, status);
    Ok(())
}

// ---------------------------------------------------------------------------
// plan
// ---------------------------------------------------------------------------

/// Returns true if all entries are converged (exit 0), false if any drift (exit 1).
pub async fn plan(
    api: Option<String>,
    token: Option<String>,
    host: String,
    profile: &Profile,
) -> Result<bool> {
    let client = crate::api::api_client(&token).await;
    let base = crate::config::resolve_api(&api, profile);
    let base = base.trim_end_matches('/');

    let resp: PlanResponse = client
        .get(format!("{}/api/forge/plan", base))
        .query(&[("host", &host)])
        .send()
        .await
        .context("failed to fetch forge plan")?
        .error_for_status()
        .context("forge plan request failed")?
        .json()
        .await
        .context("failed to parse forge plan response")?;

    println!("{:<12} {:<20} {:<36} {}", "STATUS", "KIND", "ID", "HASH");
    println!("{}", "-".repeat(74));

    let mut all_converged = true;
    for entry in &resp.entries {
        if entry.status != "converged" {
            all_converged = false;
        }
        let color = color_for_status(&entry.status);
        let hash = hash_prefix(&entry.declared_hash);
        println!(
            "{}{:<12}{} {:<20} {:<36} {}",
            color, entry.status, RESET, entry.kind, entry.id, hash
        );
    }

    if resp.entries.is_empty() {
        println!("(no entries)");
    }

    Ok(all_converged)
}

// ---------------------------------------------------------------------------
// apply
// ---------------------------------------------------------------------------

fn has_drift(entries: &[PlanEntry]) -> bool {
    entries
        .iter()
        .any(|e| matches!(e.status.as_str(), "new" | "drifted" | "missing" | "prune"))
}

fn prompt_confirm() -> Result<bool> {
    eprint!("Apply changes? Type 'yes' to confirm: ");
    std::io::stderr().flush().ok();
    let mut line = String::new();
    std::io::stdin()
        .read_line(&mut line)
        .context("failed to read confirmation")?;
    Ok(line.trim() == "yes")
}

/// Returns true if all results succeeded, false if any errored (exit 2).
pub async fn apply(
    api: Option<String>,
    token: Option<String>,
    host: String,
    yes: bool,
    all_safe: bool,
    resource: Option<String>,
    profile: &Profile,
) -> Result<bool> {
    let client = crate::api::api_client(&token).await;
    let base = crate::config::resolve_api(&api, profile);
    let base = base.trim_end_matches('/');

    // Determine keys
    let keys: serde_json::Value = if let Some(ref res) = resource {
        // Parse "KIND/ID" format
        let parts: Vec<&str> = res.splitn(2, '/').collect();
        if parts.len() != 2 {
            anyhow::bail!("--resource must be in KIND/ID format (e.g. tap/mj-abc123)");
        }
        serde_json::json!([{ "kind": parts[0], "id": parts[1] }])
    } else {
        // default: all_safe
        serde_json::json!("all_safe")
    };

    // If not --yes, fetch plan first and prompt on drift
    if !yes {
        let plan_resp: PlanResponse = client
            .get(format!("{}/api/forge/plan", base))
            .query(&[("host", &host)])
            .send()
            .await
            .context("failed to fetch plan before apply")?
            .error_for_status()
            .context("forge plan request failed")?
            .json()
            .await
            .context("failed to parse forge plan response")?;

        if has_drift(&plan_resp.entries) {
            // Show the plan
            println!("{:<12} {:<20} {:<36} {}", "STATUS", "KIND", "ID", "HASH");
            println!("{}", "-".repeat(74));
            for entry in &plan_resp.entries {
                let color = color_for_status(&entry.status);
                let hash = hash_prefix(&entry.declared_hash);
                println!(
                    "{}{:<12}{} {:<20} {:<36} {}",
                    color, entry.status, RESET, entry.kind, entry.id, hash
                );
            }
            println!();

            if !prompt_confirm()? {
                eprintln!("Aborted.");
                return Ok(true); // treat cancel as success (no error)
            }
        }
    }

    let mut body = serde_json::json!({ "host": host, "keys": keys });
    // --all-safe flag takes precedence over --resource
    if all_safe && resource.is_none() {
        body["keys"] = serde_json::json!("all_safe");
    }

    let resp: ApplyResponse = client
        .post(format!("{}/api/forge/apply", base))
        .json(&body)
        .send()
        .await
        .context("failed to send forge apply request")?
        .error_for_status()
        .context("forge apply request failed")?
        .json()
        .await
        .context("failed to parse forge apply response")?;

    let mut all_ok = true;
    for r in &resp.results {
        if r.result == "ok" {
            println!("{}  {}/{}{}", GREEN, r.kind, r.id, RESET);
        } else {
            all_ok = false;
            let reason = r.reason.as_deref().unwrap_or("unknown error");
            println!("{}x {}/{} ({}){}", RED, r.kind, r.id, reason, RESET);
        }
    }

    if resp.results.is_empty() {
        println!("(nothing applied)");
    }

    Ok(all_ok)
}

// ---------------------------------------------------------------------------
// state
// ---------------------------------------------------------------------------

pub async fn state(
    api: Option<String>,
    token: Option<String>,
    host: Option<String>,
    kind: Option<String>,
    status: Option<String>,
    profile: &Profile,
) -> Result<()> {
    let client = crate::api::api_client(&token).await;
    let base = crate::config::resolve_api(&api, profile);
    let base = base.trim_end_matches('/');

    let mut query: Vec<(&str, String)> = Vec::new();
    if let Some(ref h) = host {
        query.push(("host", h.clone()));
    }
    if let Some(ref k) = kind {
        query.push(("kind", k.clone()));
    }
    if let Some(ref s) = status {
        query.push(("status", s.clone()));
    }

    let resp: StateResponse = client
        .get(format!("{}/api/forge/state", base))
        .query(&query)
        .send()
        .await
        .context("failed to fetch forge state")?
        .error_for_status()
        .context("forge state request failed")?
        .json()
        .await
        .context("failed to parse forge state response")?;

    if resp.records.is_empty() {
        eprintln!("No state records found.");
        return Ok(());
    }

    println!(
        "{:<12} {:<20} {:<36} {:<12} {}",
        "STATUS", "KIND", "ID", "HOST", "HASH"
    );
    println!("{}", "-".repeat(88));

    for r in &resp.records {
        let color = color_for_status(&r.status);
        let hash = hash_prefix(&r.owned_hash);
        println!(
            "{}{:<12}{} {:<20} {:<36} {:<12} {}",
            color, r.status, RESET, r.kind, r.resource_id, r.host, hash
        );
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// events — audit feed + live SSE tail
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
#[allow(dead_code)]
pub struct ForgeEvent {
    pub id: Option<i64>,
    pub ts: String,
    pub host: String,
    #[serde(rename = "type")]
    pub event_type: String,
    pub kind: Option<String>,
    pub resource_id: Option<String>,
    pub status: Option<String>,
    #[serde(default)]
    pub detail: serde_json::Value,
}

#[derive(Deserialize)]
pub struct EventsResponse {
    pub events: Vec<ForgeEvent>,
}

fn color_for_type(t: &str) -> &'static str {
    match t {
        "probe" => "\x1b[2m",   // dim
        "drift" => "\x1b[33m",  // yellow
        "apply" => "\x1b[32m",  // green
        "adopt" => "\x1b[36m",  // cyan
        "ignore" => "\x1b[34m", // blue
        _ => "\x1b[0m",
    }
}

fn print_event(e: &ForgeEvent) {
    let resource = match (&e.kind, &e.resource_id) {
        (Some(k), Some(id)) => format!("{}/{}", k, id),
        _ => String::new(),
    };
    let status = e.status.as_deref().unwrap_or("");
    println!(
        "{} {}{:<7}{} {:<14} {:<28} {}",
        e.ts,
        color_for_type(&e.event_type),
        e.event_type,
        RESET,
        e.host,
        resource,
        status,
    );
}

/// Print recent audit events (most recent `limit`, or everything after `since`).
pub async fn events(
    api: Option<String>,
    token: Option<String>,
    since: Option<String>,
    limit: Option<u32>,
    profile: &Profile,
) -> Result<()> {
    let client = crate::api::api_client(&token).await;
    let base = crate::config::resolve_api(&api, profile);
    let base = base.trim_end_matches('/');

    let mut query: Vec<(&str, String)> = Vec::new();
    if let Some(ref s) = since {
        query.push(("since", s.clone()));
    }
    if let Some(l) = limit {
        query.push(("limit", l.to_string()));
    }

    let resp: EventsResponse = client
        .get(format!("{}/api/forge/events", base))
        .query(&query)
        .send()
        .await
        .context("failed to fetch forge events")?
        .error_for_status()
        .context("forge events request failed")?
        .json()
        .await
        .context("failed to parse forge events response")?;

    if resp.events.is_empty() {
        eprintln!("No events.");
        return Ok(());
    }

    for e in &resp.events {
        print_event(e);
    }

    Ok(())
}

/// Follow the live SSE stream, printing frames as they arrive. Reconnects from
/// the last-seen cursor on disconnect. Runs until interrupted (Ctrl-C).
pub async fn events_tail(
    api: Option<String>,
    token: Option<String>,
    since: Option<String>,
    profile: &Profile,
) -> Result<()> {
    use futures_util::StreamExt;

    let client = crate::api::api_client(&token).await;
    let base = crate::config::resolve_api(&api, profile);
    let base = base.trim_end_matches('/');

    let mut cursor = since;

    loop {
        let mut req = client.get(format!("{}/api/forge/events/stream", base));
        if let Some(ref c) = cursor {
            req = req.query(&[("since", c)]);
        }

        let resp = match req.send().await.and_then(|r| r.error_for_status()) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("stream connect failed: {e}; retrying in 2s");
                tokio::time::sleep(Duration::from_secs(2)).await;
                continue;
            }
        };

        let mut stream = resp.bytes_stream();
        let mut buf = String::new();

        while let Some(chunk) = stream.next().await {
            let chunk = match chunk {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("stream read error: {e}");
                    break;
                }
            };
            buf.push_str(&String::from_utf8_lossy(&chunk));

            // SSE frames are separated by a blank line ("\n\n").
            while let Some(idx) = buf.find("\n\n") {
                let frame: String = buf.drain(..idx + 2).collect();
                if let Some(event) = parse_sse_frame(&frame, &mut cursor) {
                    print_event(&event);
                }
            }
        }

        eprintln!("stream ended; reconnecting in 2s...");
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

/// Parse one SSE frame. Updates `cursor` from the `id:` line and returns the
/// decoded event from the `data:` line. Comment frames (heartbeats) yield None.
fn parse_sse_frame(frame: &str, cursor: &mut Option<String>) -> Option<ForgeEvent> {
    let mut data: Option<&str> = None;

    for line in frame.lines() {
        if let Some(rest) = line.strip_prefix("id:") {
            *cursor = Some(rest.trim().to_string());
        } else if let Some(rest) = line.strip_prefix("data:") {
            data = Some(rest.trim());
        }
        // Lines starting with ':' (comments/keepalives) and 'event:' are ignored.
    }

    data.and_then(|d| serde_json::from_str::<ForgeEvent>(d).ok())
}
