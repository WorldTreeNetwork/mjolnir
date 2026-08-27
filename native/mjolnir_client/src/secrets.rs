//! `mj secrets` — host-escrowed deploy secrets for an app.
//!
//!   mj secrets set <app> KEY           prompt (hidden) then PUT
//!   mj secrets set <app> KEY --stdin   read value from stdin
//!   mj secrets set <app> KEY=VALUE     inline (lands in shell history)
//!   mj secrets ls   <app>              GET names only
//!   mj secrets unset <app> KEY         DELETE

use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::io::{self, IsTerminal, Read, Write};

use crate::api::{api_client, send_text};
use crate::config::Profile;

#[derive(Deserialize)]
struct SecretsBody {
    app: String,
    slug: Option<String>,
    keys: Vec<String>,
    set: Option<Vec<String>>,
    unset: Option<String>,
}

pub async fn cmd_secrets_set(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    app: &str,
    spec: &str,
    stdin: bool,
    json: bool,
) -> Result<()> {
    let (key, value) = resolve_pair(spec, stdin)?;
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let body = send_text(
        client
            .put(format!("{}/api/apps/{}/secrets", base, app))
            .json(&serde_json::json!({
                "key": key,
                "value": value,
            })),
        "secrets set",
    )
    .await?;

    if json {
        println!("{}", body);
        return Ok(());
    }

    let resp: SecretsBody = serde_json::from_str(&body).context("failed to parse secrets set")?;
    println!("App:   {}", resp.app);
    if let Some(slug) = resp.slug {
        println!("Slug:  {}", slug);
    }
    println!("Set:   {}", resp.set.unwrap_or_default().join(", "));
    println!("Keys:  {}", resp.keys.join(", "));
    println!("Redeploy the app to inject this into the guest.");
    Ok(())
}

pub async fn cmd_secrets_ls(
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
        client.get(format!("{}/api/apps/{}/secrets", base, app)),
        "secrets ls",
    )
    .await?;

    if json {
        println!("{}", body);
        return Ok(());
    }

    let resp: SecretsBody = serde_json::from_str(&body).context("failed to parse secrets ls")?;
    if resp.keys.is_empty() {
        println!("{}: (no secrets)", resp.app);
        return Ok(());
    }
    println!("{}:", resp.app);
    for key in resp.keys {
        println!("  {}", key);
    }
    Ok(())
}

pub async fn cmd_secrets_unset(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    app: &str,
    key: &str,
    json: bool,
) -> Result<()> {
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');
    let body = send_text(
        client.delete(format!("{}/api/apps/{}/secrets/{}", base, app, key)),
        "secrets unset",
    )
    .await?;

    if json {
        println!("{}", body);
        return Ok(());
    }

    let resp: SecretsBody = serde_json::from_str(&body).context("failed to parse secrets unset")?;
    println!(
        "Unset {} on {}",
        resp.unset.unwrap_or_else(|| key.to_string()),
        resp.app
    );
    Ok(())
}

fn resolve_pair(spec: &str, stdin: bool) -> Result<(String, String)> {
    let (key, inline) = split_spec(spec)?;
    if stdin {
        if inline.is_some() {
            bail!("pass KEY with --stdin, not KEY=VALUE");
        }
        let mut buf = String::new();
        io::stdin()
            .read_to_string(&mut buf)
            .context("failed to read secret from stdin")?;
        let value = buf.trim_end_matches(['\n', '\r']).to_string();
        if value.is_empty() {
            bail!("empty secret on stdin");
        }
        return Ok((key, value));
    }
    if let Some(value) = inline {
        if value.is_empty() {
            bail!("empty value");
        }
        return Ok((key, value));
    }
    if !io::stdin().is_terminal() {
        bail!("not a tty: pass --stdin or KEY=VALUE");
    }
    eprint!("{}: ", key);
    io::stderr().flush().ok();
    let value = rpassword::read_password().context("failed to read secret")?;
    if value.is_empty() {
        bail!("empty secret");
    }
    Ok((key, value))
}

fn split_spec(spec: &str) -> Result<(String, Option<String>)> {
    match spec.split_once('=') {
        Some((key, value)) => {
            if key.is_empty() {
                bail!("missing key");
            }
            Ok((key.to_string(), Some(value.to_string())))
        }
        None => {
            if spec.is_empty() {
                bail!("missing key");
            }
            Ok((spec.to_string(), None))
        }
    }
}
