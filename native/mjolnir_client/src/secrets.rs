//! `mj secrets` — host-escrowed deploy secrets for an app.
//!
//!   mj secrets set <app> KEY                     prompt (hidden) then PUT
//!   mj secrets set <app> KEY --stdin             read value from stdin
//!   mj secrets set <app> KEY=VALUE [KEY=VALUE]…  one merge, one write
//!   mj secrets ls   <app>                        GET names only
//!   mj secrets unset <app> KEY                   DELETE
//!
//! A usage error for this command must not contain a spec value. Clap's
//! default renderer quotes the raw argv; [`redact_secret_values`] strips
//! the part after `=` before that text reaches stderr.

use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::collections::BTreeMap;
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
    specs: &[String],
    stdin: bool,
    json: bool,
) -> Result<()> {
    let entries = resolve_entries(specs, stdin)?;
    if specs.iter().any(|spec| spec.contains('=')) {
        eprintln!(
            "warning: a value was passed on the command line (shell history and process list). \
             Prefer: mj secrets set {app} KEY --stdin"
        );
    }
    let client = api_client(token).await;
    let api = crate::config::resolve_api(api_flag, profile);
    let base = api.trim_end_matches('/');

    let body = send_text(
        client
            .put(format!("{}/api/apps/{}/secrets", base, app))
            .json(&entries_body(&entries)),
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

/// Clap value parser for a secrets spec. Rejects an empty key here so the
/// failure stays in argv parsing; the error text still quotes the raw spec,
/// which [`redact_secret_values`] removes.
pub fn parse_secret_spec(raw: &str) -> Result<String, String> {
    if raw.is_empty() || raw.starts_with('=') {
        return Err("missing key".into());
    }
    Ok(raw.to_string())
}

/// Remove spec values from a secrets-command usage error.
///
/// `argv` is the process arguments without the program name. Redaction runs
/// only when that list contains the `secrets` subcommand, so other commands
/// keep clap's normal errors. Each `KEY=VALUE` argument is rewritten to
/// `KEY=[redacted]`, and a clap-quoted bare value is rewritten too.
pub fn redact_secret_values(msg: &str, argv: &[impl AsRef<str>]) -> String {
    let args: Vec<&str> = argv.iter().map(AsRef::as_ref).collect();
    if !args.iter().any(|arg| *arg == "secrets") {
        return msg.to_string();
    }
    let mut out = msg.to_string();
    for arg in args {
        let Some((key, value)) = arg.split_once('=') else {
            continue;
        };
        if value.is_empty() {
            continue;
        }
        out = out.replace(arg, &format!("{key}=[redacted]"));
        out = out.replace(&format!("'{value}'"), "'[redacted]'");
        out = out.replace(&format!("\"{value}\""), "\"[redacted]\"");
    }
    out
}

/// JSON body for one `PUT /api/apps/:app/secrets`. The server merges `entries`
/// in a single file write.
pub(crate) fn entries_body(entries: &BTreeMap<String, String>) -> serde_json::Value {
    serde_json::json!({ "entries": entries })
}

pub(crate) fn resolve_entries(specs: &[String], stdin: bool) -> Result<BTreeMap<String, String>> {
    if specs.is_empty() {
        bail!("missing key");
    }
    if stdin {
        if specs.len() != 1 {
            bail!("--stdin reads one KEY; pass a single KEY");
        }
        let (key, value) = resolve_pair(&specs[0], true)?;
        return Ok(BTreeMap::from([(key, value)]));
    }

    let parsed = specs
        .iter()
        .map(|spec| split_spec(spec))
        .collect::<Result<Vec<_>>>()?;
    let inline_count = parsed.iter().filter(|(_, value)| value.is_some()).count();
    if inline_count == 0 {
        if parsed.len() != 1 {
            bail!("pass KEY=VALUE for each secret, or a single KEY to prompt");
        }
        let (key, value) = resolve_pair(&specs[0], false)?;
        return Ok(BTreeMap::from([(key, value)]));
    }
    if inline_count != parsed.len() {
        bail!("pass KEY=VALUE for every secret when setting more than one");
    }

    let mut entries = BTreeMap::new();
    for (key, value) in parsed {
        let Some(value) = value else {
            bail!("pass KEY=VALUE for every secret when setting more than one");
        };
        if value.is_empty() {
            bail!("empty value for {key}");
        }
        if entries.insert(key.clone(), value).is_some() {
            bail!("duplicate key {key}");
        }
    }
    Ok(entries)
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

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(s: &str) -> String {
        s.to_string()
    }

    #[test]
    fn two_inline_specs_are_one_entries_body() {
        let entries = resolve_entries(&[spec("A=1"), spec("B=2")], false).unwrap();
        let body = entries_body(&entries);
        assert_eq!(body["entries"]["A"], "1");
        assert_eq!(body["entries"]["B"], "2");
        assert!(body.get("key").is_none());
        assert!(body.get("value").is_none());
    }

    #[test]
    fn mixed_specs_error_omits_the_value() {
        let err =
            resolve_entries(&[spec("TOKEN=sentinel-value-9f3a"), spec("BARE")], false).unwrap_err();
        let msg = format!("{err:#}");
        assert!(!msg.contains("sentinel-value-9f3a"), "{msg}");
    }

    #[test]
    fn duplicate_key_error_omits_the_value() {
        let err = resolve_entries(
            &[spec("TOKEN=sentinel-value-9f3a"), spec("TOKEN=other")],
            false,
        )
        .unwrap_err();
        let msg = format!("{err:#}");
        assert!(msg.contains("duplicate key TOKEN"), "{msg}");
        assert!(!msg.contains("sentinel-value-9f3a"), "{msg}");
        assert!(!msg.contains("other"), "{msg}");
    }

    #[test]
    fn redacts_quoted_spec_from_a_usage_error() {
        let argv = [
            "secrets",
            "set",
            "app",
            "TOKEN=sentinel-value-9f3a",
            "--not-a-flag",
        ];
        let msg = "error: unexpected argument 'TOKEN=sentinel-value-9f3a' found\n";
        let redacted = redact_secret_values(msg, &argv);
        assert!(!redacted.contains("sentinel-value-9f3a"), "{redacted}");
        assert!(redacted.contains("TOKEN=[redacted]"), "{redacted}");
    }

    #[test]
    fn redacts_bare_quoted_value() {
        let argv = ["secrets", "set", "app", "=sentinel-value-9f3a"];
        let msg = "error: invalid value 'sentinel-value-9f3a' for '<SPEC>': missing key\n";
        let redacted = redact_secret_values(msg, &argv);
        assert!(!redacted.contains("sentinel-value-9f3a"), "{redacted}");
        assert!(redacted.contains("'[redacted]'"), "{redacted}");
    }

    #[test]
    fn leaves_other_commands_alone() {
        let argv = ["spawn", "--snapshot=sentinel-value-9f3a"];
        let msg = "error: unexpected argument '--snapshot=sentinel-value-9f3a' found\n";
        assert_eq!(redact_secret_values(msg, &argv), msg);
    }
}
