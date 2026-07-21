//! `mj domain` subcommand group — manage custom domains for deployed apps.
//!
//!   mj domain set <app> <fqdn>   bind a custom domain (PUT /api/apps/:app/domain)
//!   mj domain rm  <app>          remove it (DELETE /api/apps/:app/domain)
//!   mj domain ls                 list apps + their domains (GET /api/apps)
//!
//! With `--keypair-file`, `set`/`rm` instead target an IdentiKey **site**: the
//! positional is the site name and the domain is bound via a signed alias
//! record. That path lives in `sites::cmd_alias_set` / `sites::cmd_alias_rm`,
//! next to the rest of the byte-exact envelope code.

use anyhow::{Context, Result};
use serde::Deserialize;

use crate::api::{api_client, send_text};
use crate::config::Profile;

/// Response from `PUT /api/apps/:app/domain`.
#[derive(Deserialize)]
struct DomainSetResponse {
    app: String,
    fqdn: String,
    backend: Option<String>,
    apex_registered: bool,
    cert_present: bool,
}

/// Response from `DELETE /api/apps/:app/domain`.
#[derive(Deserialize)]
struct DomainRmResponse {
    app: String,
    #[allow(dead_code)]
    removed: bool,
}

/// One entry of `GET /api/apps`.
#[derive(Deserialize)]
struct AppSummary {
    app_name: String,
    url: Option<String>,
    custom_domain: Option<String>,
    #[allow(dead_code)]
    service_vm_id: Option<String>,
    backend: Option<String>,
    #[allow(dead_code)]
    port: Option<u16>,
}

/// `GET /api/apps` wraps the entries in `{"apps": [...]}`.
#[derive(Deserialize)]
struct AppsList {
    apps: Vec<AppSummary>,
}

/// `mj domain set <app> <fqdn>` — bind a custom domain to an app.
pub async fn cmd_domain_set(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    app: &str,
    fqdn: &str,
    json: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let body = send_text(
        client
            .put(format!("{}/api/apps/{}/domain", base, app))
            .json(&serde_json::json!({ "fqdn": fqdn })),
        "domain set",
    )
    .await?;

    if json {
        println!("{}", body);
        return Ok(());
    }

    let resp: DomainSetResponse =
        serde_json::from_str(&body).context("failed to parse domain set response")?;

    println!("App:      {}", resp.app);
    println!("Domain:   {}", resp.fqdn);
    println!("Backend:  {}", resp.backend.as_deref().unwrap_or("-"));
    println!(
        "Apex:     {}",
        if resp.apex_registered {
            "\x1b[32mregistered\x1b[0m"
        } else {
            "\x1b[33mnot registered\x1b[0m"
        }
    );
    println!(
        "Cert:     {}",
        if resp.cert_present {
            "\x1b[32mpresent\x1b[0m"
        } else {
            "\x1b[33mmissing\x1b[0m"
        }
    );

    if !resp.apex_registered {
        eprintln!(
            "\x1b[33mwarning: the apex of '{}' is not registered with the gateway — \
             add it to MJOLNIR_GATEWAY_APEXES (or a [[domain]] config entry) so the \
             gateway will serve this host.\x1b[0m",
            resp.fqdn
        );
    }
    if !resp.cert_present {
        eprintln!(
            "\x1b[33mwarning: no TLS certificate is present for '{}' — it must be \
             provisioned before HTTPS will work.\x1b[0m",
            resp.fqdn
        );
    }

    Ok(())
}

/// `mj domain rm <app>` — remove an app's custom domain.
pub async fn cmd_domain_rm(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    app: &str,
    json: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let body = send_text(
        client.delete(format!("{}/api/apps/{}/domain", base, app)),
        "domain rm",
    )
    .await?;

    if json {
        println!("{}", body);
        return Ok(());
    }

    let resp: DomainRmResponse =
        serde_json::from_str(&body).context("failed to parse domain rm response")?;
    eprintln!("Removed custom domain for {}", resp.app);
    Ok(())
}

/// `mj domain ls` — list apps with their URLs, custom domains, and backends.
pub async fn cmd_domain_ls(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    json: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let body = send_text(client.get(format!("{}/api/apps", base)), "apps list").await?;

    if json {
        println!("{}", body);
        return Ok(());
    }

    let apps: Vec<AppSummary> = serde_json::from_str::<AppsList>(&body)
        .context("failed to parse apps list response")?
        .apps;

    if apps.is_empty() {
        eprintln!("No apps deployed.");
        return Ok(());
    }

    println!(
        "{:<24} {:<40} {:<28} {}",
        "APP", "URL", "CUSTOM DOMAIN", "BACKEND"
    );
    for a in &apps {
        println!(
            "{:<24} {:<40} {:<28} {}",
            a.app_name,
            a.url.as_deref().unwrap_or("-"),
            a.custom_domain.as_deref().unwrap_or("-"),
            a.backend.as_deref().unwrap_or("-"),
        );
    }
    Ok(())
}
