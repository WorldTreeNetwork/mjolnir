//! Locating the Mjolnir host API base, shared by the CLI and external apps.
//!
//! The host you configured for the `mjolnir` CLI — the `MJOLNIR_API` env var, or
//! the `default` profile's `api` in the platform config dir's
//! `mjolnir/profiles.toml` (macOS: `~/Library/Application Support/mjolnir/`,
//! Linux: `~/.config/mjolnir/`) — is the single source of truth. Apps ride it
//! the same way they ride the [`crate::auth`] token store, so a logged-in user
//! never has to re-enter a URL.

use std::collections::HashMap;
use std::path::PathBuf;

use serde::Deserialize;

fn profiles_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("mjolnir")
        .join("profiles.toml")
}

/// One `[<name>]` section of `profiles.toml`. Only `api` is read here; other
/// keys (host, ssh_key, …) are ignored.
#[derive(Deserialize)]
struct ProfileEntry {
    api: Option<String>,
}

/// Resolve the Mjolnir host API base from the same sources the CLI uses, minus
/// the dev `localhost` fallback: the `MJOLNIR_API` env var, then the `default`
/// profile's `api` in `mjolnir/profiles.toml`. Returns `None` when nothing is
/// configured, so callers can prompt instead of guessing a host (and so a host
/// is never baked into the binary — it stays config-driven).
pub fn resolve_api_base() -> Option<String> {
    if let Ok(api) = std::env::var("MJOLNIR_API") {
        let api = api.trim();
        if !api.is_empty() {
            return Some(api.to_string());
        }
    }

    let text = std::fs::read_to_string(profiles_path()).ok()?;
    let profiles: HashMap<String, ProfileEntry> = toml::from_str(&text).ok()?;
    profiles
        .get("default")
        .and_then(|p| p.api.as_deref())
        .map(str::trim)
        .filter(|api| !api.is_empty())
        .map(str::to_string)
}
