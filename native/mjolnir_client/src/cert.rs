//! `mj cert` subcommand group — issue and list custom-domain TLS certs.
//!
//!   mj cert issue <fqdn>   HTTP-01 issue on the host (POST /api/certs/issue)
//!   mj cert ls             list installed [[cert]] entries (GET /api/certs)
//!
//! Wildcards (`*.`) are refused. Issuance runs on the host; this client never
//! receives PEMs.

use anyhow::{Context, Result};
use serde::Deserialize;

use crate::api::{api_client, send_text};
use crate::config::Profile;

/// Response from `POST /api/certs/issue`. No PEM fields.
#[derive(Deserialize)]
struct CertIssueResponse {
    fqdn: String,
    status: String,
    not_after: Option<String>,
}

/// One entry of `GET /api/certs`.
#[derive(Deserialize)]
struct CertSummary {
    host: Option<String>,
    not_after: Option<String>,
    issuer: Option<String>,
    #[allow(dead_code)]
    sans: Option<Vec<String>>,
}

/// `GET /api/certs` wraps the entries in `{"certs": [...]}`.
#[derive(Deserialize)]
struct CertsList {
    certs: Vec<CertSummary>,
}

/// `mj cert issue <fqdn>` — ask the host to HTTP-01 issue and install [[cert]].
pub async fn cmd_cert_issue(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    fqdn: &str,
    json: bool,
) -> Result<()> {
    if fqdn.starts_with("*.") {
        anyhow::bail!("wildcards are not supported; HTTP-01 issues exact names only");
    }

    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let body = send_text(
        client
            .post(format!("{}/api/certs/issue", base))
            .json(&serde_json::json!({ "fqdn": fqdn })),
        "cert issue",
    )
    .await?;

    if json {
        println!("{}", body);
        return Ok(());
    }

    let resp: CertIssueResponse =
        serde_json::from_str(&body).context("failed to parse cert issue response")?;

    println!("Domain:    {}", resp.fqdn);
    println!("Status:    {}", resp.status);
    println!("Not after: {}", resp.not_after.as_deref().unwrap_or("-"));
    Ok(())
}

/// `mj cert ls` — list installed [[cert]] hosts (no PEMs).
pub async fn cmd_cert_ls(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    json: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let body = send_text(client.get(format!("{}/api/certs", base)), "certs list").await?;

    if json {
        println!("{}", body);
        return Ok(());
    }

    let certs: Vec<CertSummary> = serde_json::from_str::<CertsList>(&body)
        .context("failed to parse certs list response")?
        .certs;

    if certs.is_empty() {
        eprintln!("No custom-domain certificates installed.");
        return Ok(());
    }

    println!("{:<40} {:<28} {}", "HOST", "NOT AFTER", "ISSUER");
    for c in &certs {
        println!(
            "{:<40} {:<28} {}",
            c.host.as_deref().unwrap_or("-"),
            c.not_after.as_deref().unwrap_or("-"),
            c.issuer.as_deref().unwrap_or("-"),
        );
    }
    Ok(())
}
