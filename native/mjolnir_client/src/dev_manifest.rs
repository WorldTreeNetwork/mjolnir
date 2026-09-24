//! `[targets.<name>]` in `mjolnir.toml`. Prod keys are ignored here.
//! The Elixir `Mjolnir.Deploy.Manifest.load_target/2` is the same contract.

use anyhow::{bail, Context, Result};
use std::collections::BTreeMap;
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DevTarget {
    pub base: Option<String>,
    pub snapshot: Option<String>,
    pub memory_mb: u32,
    pub port: u16,
    pub workdir: Option<String>,
    pub command: String,
    pub preserve_iroh_key: bool,
    pub git_remote: Option<String>,
    pub git_sign: bool,
    pub env: BTreeMap<String, String>,
}

pub fn load(dir: &Path, name: &str) -> Result<DevTarget> {
    let path = dir.join("mjolnir.toml");
    let raw = std::fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
    parse(&raw, name)
}

pub fn parse(raw: &str, name: &str) -> Result<DevTarget> {
    let value: toml::Value = toml::from_str(raw).context("mjolnir.toml is not valid TOML")?;
    let root = value.as_table().context("mjolnir.toml must be a table")?;
    let Some(targets) = root.get("targets") else {
        bail!("mjolnir.toml has no [targets] table");
    };
    let targets = targets.as_table().context("[targets] must be a table")?;
    let Some(dev) = targets.get(name) else {
        bail!("mjolnir.toml has no [targets.{name}]");
    };
    let dev = dev.as_table().context("[targets.{name}] must be a table")?;

    let command = req_string(dev, "command")?;
    let base = opt_name(dev, "base")?;
    let snapshot = opt_name(dev, "snapshot")?;
    if base.is_none() && snapshot.is_none() {
        bail!("[targets.{name}] needs base or snapshot");
    }
    let memory_mb = opt_int(dev, "memory_mb", 2048, 128, 32_768)?;
    let port = opt_int(dev, "port", 80, 1, 65_535)? as u16;
    let workdir = opt_string(dev, "workdir")?;
    let preserve_iroh_key = opt_bool(dev, "preserve_iroh_key", snapshot.is_some())?;
    let env = env_table(dev)?;
    let (git_remote, git_sign) = git_table(dev)?;

    Ok(DevTarget {
        base,
        snapshot,
        memory_mb,
        port,
        workdir,
        command,
        preserve_iroh_key,
        git_remote,
        git_sign,
        env,
    })
}

/// Install a systemd unit so the target command comes back on guest boot,
/// then start it. Safe to run again.
pub fn start_script(name: &str, dev: &DevTarget) -> String {
    let workdir = dev.workdir.as_deref().unwrap_or("/");
    let unit = format!("mjolnir-target-{}.service", sanitize_unit(name));
    let mut env_lines = String::new();
    for (k, v) in &dev.env {
        env_lines.push_str(&format!("Environment={}={}\n", k, systemd_env(v)));
    }
    let inner = format!(
        "export PATH=/root/.bun/bin:$PATH; cd {workdir}; exec {cmd}",
        cmd = dev.command
    );
    format!(
        r#"set -e
unit=/etc/systemd/system/{unit}
cat > "$unit" <<'UNIT'
[Unit]
Description=Mjolnir target {name}
After=network-online.target
[Service]
WorkingDirectory={workdir}
{env_lines}ExecStart=/bin/bash -lc {exec}
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
UNIT
tmux kill-window -t main:{name} 2>/dev/null || true
systemctl daemon-reload
systemctl enable "$unit"
systemctl restart "$unit"
systemctl is-active "$unit"
"#,
        unit = unit,
        name = name,
        workdir = workdir,
        env_lines = env_lines,
        exec = sh_single(&inner),
    )
}

fn sanitize_unit(name: &str) -> String {
    name.chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' })
        .collect()
}

fn systemd_env(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

fn sh_single(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

fn req_string(table: &toml::map::Map<String, toml::Value>, key: &str) -> Result<String> {
    match table.get(key) {
        Some(toml::Value::String(s)) if !s.trim().is_empty() => Ok(s.clone()),
        Some(other) => bail!("{key} must be a non-blank string, got {other}"),
        None => bail!("{key} is required"),
    }
}

fn opt_string(table: &toml::map::Map<String, toml::Value>, key: &str) -> Result<Option<String>> {
    match table.get(key) {
        None => Ok(None),
        Some(toml::Value::String(s)) if s.is_empty() => Ok(None),
        Some(toml::Value::String(s)) => Ok(Some(s.clone())),
        Some(other) => bail!("{key} must be a string, got {other}"),
    }
}

fn opt_name(table: &toml::map::Map<String, toml::Value>, key: &str) -> Result<Option<String>> {
    match opt_string(table, key)? {
        None => Ok(None),
        Some(s) if s.contains(['/', ' ', '.']) && s.contains("..") => {
            bail!("{key} must be a single path segment")
        }
        Some(s) if s.contains('/') || s.contains("..") || s.contains(' ') => {
            bail!("{key} must be a single path segment")
        }
        Some(s) => Ok(Some(s)),
    }
}

fn opt_int(
    table: &toml::map::Map<String, toml::Value>,
    key: &str,
    default: i64,
    min: i64,
    max: i64,
) -> Result<u32> {
    let n = match table.get(key) {
        None => default,
        Some(toml::Value::Integer(n)) => *n,
        Some(other) => bail!("{key} must be an integer, got {other}"),
    };
    if n < min || n > max {
        bail!("{key} must be {min}-{max}, got {n}");
    }
    Ok(n as u32)
}

fn opt_bool(table: &toml::map::Map<String, toml::Value>, key: &str, default: bool) -> Result<bool> {
    match table.get(key) {
        None => Ok(default),
        Some(toml::Value::Boolean(b)) => Ok(*b),
        Some(other) => bail!("{key} must be a boolean, got {other}"),
    }
}

fn env_table(dev: &toml::map::Map<String, toml::Value>) -> Result<BTreeMap<String, String>> {
    let Some(env) = dev.get("env") else {
        return Ok(BTreeMap::new());
    };
    let env = env.as_table().context("[dev.env] must be a table")?;
    let mut out = BTreeMap::new();
    for (k, v) in env {
        let toml::Value::String(s) = v else {
            bail!("dev.env {k} must be a string");
        };
        if s.contains(['\n', '\r']) {
            bail!("dev.env {k} must be a single line");
        }
        out.insert(k.clone(), s.clone());
    }
    Ok(out)
}

fn git_table(dev: &toml::map::Map<String, toml::Value>) -> Result<(Option<String>, bool)> {
    let Some(git) = dev.get("git") else {
        return Ok((None, false));
    };
    let git = git.as_table().context("[dev.git] must be a table")?;
    Ok((opt_string(git, "remote")?, opt_bool(git, "sign", false)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prod_keys_do_not_hide_dev() {
        let dev = parse(
            r#"
            start_command = "node build"
            port = 3000
            [targets.dev]
            snapshot = "hosted-devpreview-test"
            base = "ubuntu-24.04"
            command = "bun run dev --host 0.0.0.0 --port 80"
            [targets.dev.env]
            VITE_MEDUSA_BACKEND_URL = "https://api.hypersigil.world"
            [targets.dev.git]
            remote = "forgejo"
            sign = true
            "#,
            "dev",
        )
        .unwrap();
        assert_eq!(dev.snapshot.as_deref(), Some("hosted-devpreview-test"));
        assert!(dev.preserve_iroh_key);
        assert!(dev.git_sign);
        assert_eq!(dev.port, 80);
        assert_eq!(
            dev.env.get("VITE_MEDUSA_BACKEND_URL").map(String::as_str),
            Some("https://api.hypersigil.world")
        );
    }

    #[test]
    fn missing_root_errors() {
        let err = parse("[targets.dev]\ncommand = \"bun run dev\"\n", "dev").unwrap_err();
        assert!(err.to_string().contains("base or snapshot"));
    }
}
