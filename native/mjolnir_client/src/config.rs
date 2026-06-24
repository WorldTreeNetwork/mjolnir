//! Persistent CLI configuration (~/.config/mjolnir/profiles.toml).
//!
//! Supports multiple named profiles. The "default" profile is used when no
//! --profile flag is given. Automatically migrates from the old config.json
//! format on first run.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;

const DEFAULT_API: &str = "http://localhost:4000";

/// All named profiles, stored as a flat TOML table.
#[derive(Serialize, Deserialize, Default)]
pub struct Profiles {
    #[serde(flatten)]
    pub profiles: BTreeMap<String, Profile>,
}

/// A single named profile.
#[derive(Serialize, Deserialize, Default, Clone)]
pub struct Profile {
    pub api: Option<String>,
    pub host: Option<String>,
    pub ssh_key: Option<String>,
    pub setup_source: Option<String>,
}

/// Old JSON config format — used only for migration.
#[derive(Deserialize, Default)]
struct OldConfig {
    api: Option<String>,
    ssh_key: Option<String>,
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/// Returns `~/.config/mjolnir/`.
pub fn config_dir() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("mjolnir")
}

/// Returns `~/.config/mjolnir/profiles.toml`.
pub fn profiles_path() -> PathBuf {
    config_dir().join("profiles.toml")
}

// ---------------------------------------------------------------------------
// Load / save
// ---------------------------------------------------------------------------

/// Load all profiles from disk. Migrates from config.json if needed.
/// Returns an empty `Profiles` if the file does not exist.
pub fn load_profiles() -> Profiles {
    maybe_migrate_json_config();

    let path = profiles_path();
    let data = match std::fs::read_to_string(&path) {
        Ok(d) => d,
        Err(_) => return Profiles::default(),
    };
    toml::from_str(&data).unwrap_or_default()
}

fn save_profiles(profiles: &Profiles) -> Result<()> {
    let path = profiles_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("create config dir {}", parent.display()))?;
    }
    let toml_str = toml::to_string_pretty(profiles).context("serialize profiles to TOML")?;
    std::fs::write(&path, &toml_str).with_context(|| format!("write {}", path.display()))?;
    Ok(())
}

/// If `config.json` exists but `profiles.toml` does not, migrate the old
/// config into the `[default]` profile, rename `config.json` to
/// `config.json.bak`, and print a notice to stderr.
pub fn maybe_migrate_json_config() {
    let dir = config_dir();
    let json_path = dir.join("config.json");
    let toml_path = profiles_path();

    if !json_path.exists() || toml_path.exists() {
        return;
    }

    let data = match std::fs::read_to_string(&json_path) {
        Ok(d) => d,
        Err(_) => return,
    };

    let old: OldConfig = serde_json::from_str(&data).unwrap_or_default();

    let mut profiles = Profiles::default();
    profiles.profiles.insert(
        "default".to_string(),
        Profile {
            api: old.api,
            ssh_key: old.ssh_key,
            host: None,
            setup_source: None,
        },
    );

    if let Ok(toml_str) = toml::to_string_pretty(&profiles) {
        if let Some(parent) = toml_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if std::fs::write(&toml_path, &toml_str).is_ok() {
            let bak = dir.join("config.json.bak");
            let _ = std::fs::rename(&json_path, &bak);
            eprintln!(
                "Migrated ~/.config/mjolnir/config.json -> profiles.toml (backup: config.json.bak)"
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Profile resolution
// ---------------------------------------------------------------------------

/// Return the named profile (or "default" if `name` is `None`).
/// Returns an empty `Profile` if not found.
pub fn resolve_profile(name: &Option<String>) -> Profile {
    let key = name.as_deref().unwrap_or("default");
    let profiles = load_profiles();
    profiles.profiles.get(key).cloned().unwrap_or_default()
}

// ---------------------------------------------------------------------------
// Value resolution
// ---------------------------------------------------------------------------

/// Resolve API URL: `--api` flag > `MJOLNIR_API` env > profile.api > default.
pub fn resolve_api(flag: &Option<String>, profile: &Profile) -> String {
    if let Some(ref api) = flag {
        return api.clone();
    }
    if let Ok(api) = std::env::var("MJOLNIR_API") {
        if !api.is_empty() {
            return api;
        }
    }
    profile
        .api
        .clone()
        .unwrap_or_else(|| DEFAULT_API.to_string())
}

/// Resolve SSH host: `--host` flag > `MJOLNIR_HOST` env > profile.host > error.
pub fn resolve_host(flag: &Option<String>, profile: &Profile) -> Result<String> {
    if let Some(ref h) = flag {
        return Ok(h.clone());
    }
    if let Ok(h) = std::env::var("MJOLNIR_HOST") {
        if !h.is_empty() {
            return Ok(h);
        }
    }
    if let Some(ref h) = profile.host {
        return Ok(h.clone());
    }
    bail!(
        "No host configured. Set one with:\n  mjolnir config set host root@<server>\nor pass --host <user@server>"
    )
}

// ---------------------------------------------------------------------------
// Config mutation
// ---------------------------------------------------------------------------

/// Set a key in the given profile (defaults to "default"). Supported keys: api, host, ssh_key,
/// setup_source.
pub fn set_in(profile_name: &str, key: &str, value: &str) -> Result<()> {
    let mut profiles = load_profiles();
    let profile = profiles
        .profiles
        .entry(profile_name.to_string())
        .or_default();

    match key {
        "api" => profile.api = Some(value.to_string()),
        "host" => profile.host = Some(value.to_string()),
        "ssh_key" | "ssh-key" => profile.ssh_key = Some(value.to_string()),
        "setup_source" | "setup-source" => profile.setup_source = Some(value.to_string()),
        _ => bail!(
            "Unknown config key: {}. Valid keys: api, host, ssh_key, setup_source",
            key
        ),
    }

    save_profiles(&profiles)?;
    eprintln!("Set [{}] {} = {}", profile_name, key, value);
    Ok(())
}

pub fn set(key: &str, value: &str) -> Result<()> {
    set_in("default", key, value)
}

// ---------------------------------------------------------------------------
// Display
// ---------------------------------------------------------------------------

/// Show resolved values for the default profile.
pub fn show() {
    let path = profiles_path();
    let profile = resolve_profile(&None);
    let api = resolve_api(&None, &profile);
    println!("Config:  {}", path.display());
    println!("Profile: default");
    println!(
        "API:     {}",
        if profile.api.is_some() {
            api.clone()
        } else {
            format!("(default) {}", api)
        }
    );
    if let Some(ref h) = profile.host {
        println!("Host:    {}", h);
    } else {
        println!("Host:    (not set)");
    }
    println!(
        "SSH key: {}",
        profile.ssh_key.as_deref().unwrap_or("(auto-detect)")
    );
    if let Some(ref src) = profile.setup_source {
        println!("Setup:   {}", src);
    }
}

/// List all profile names with their api and host values.
pub fn show_profiles() {
    let profiles = load_profiles();
    if profiles.profiles.is_empty() {
        println!("No profiles configured.");
        return;
    }
    println!("{:<20} {:<40} {}", "PROFILE", "API", "HOST");
    for (name, p) in &profiles.profiles {
        println!(
            "{:<20} {:<40} {}",
            name,
            p.api.as_deref().unwrap_or("(default)"),
            p.host.as_deref().unwrap_or("-"),
        );
    }
}

// ---------------------------------------------------------------------------
// SSH key helpers
// ---------------------------------------------------------------------------

/// Resolve the SSH public key path.
/// Order: default profile's ssh_key > ~/.ssh/id_ed25519.pub > ~/.ssh/id_rsa.pub
pub fn resolve_ssh_key_path() -> Option<String> {
    let profile = resolve_profile(&None);
    resolve_ssh_key_path_for_profile(&profile)
}

/// Resolve the SSH public key path for a specific profile.
pub fn resolve_ssh_key_path_for_profile(profile: &Profile) -> Option<String> {
    if let Some(ref path) = profile.ssh_key {
        return Some(path.clone());
    }

    if let Some(home) = dirs::home_dir() {
        let candidates = [
            home.join(".ssh/id_ed25519.pub"),
            home.join(".ssh/id_rsa.pub"),
        ];
        for path in &candidates {
            if path.exists() {
                return Some(path.to_string_lossy().to_string());
            }
        }
    }

    None
}

/// Read the SSH public key content, checking the profile's ssh_key path first,
/// then falling back to auto-detected locations.
pub fn read_ssh_public_key(profile: &Profile) -> Option<String> {
    let path = resolve_ssh_key_path_for_profile(profile)?;
    std::fs::read_to_string(&path).ok()
}
