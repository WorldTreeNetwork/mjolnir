//! Persistent CLI configuration (~/.config/mjolnir/config.json).

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

const DEFAULT_API: &str = "http://localhost:4000";

#[derive(Serialize, Deserialize, Default)]
pub struct Config {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub api: Option<String>,
}

fn config_path() -> PathBuf {
    let config_dir = dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("mjolnir");
    config_dir.join("config.json")
}

impl Config {
    pub fn load() -> Self {
        let path = config_path();
        std::fs::read_to_string(&path)
            .ok()
            .and_then(|data| serde_json::from_str(&data).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) -> Result<(), Box<dyn std::error::Error>> {
        let path = config_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let json = serde_json::to_string_pretty(self)?;
        std::fs::write(&path, &json)?;
        Ok(())
    }
}

/// Resolve API URL: --api flag > MJOLNIR_API env > config file > default.
pub fn resolve_api(flag: &Option<String>) -> String {
    if let Some(ref api) = flag {
        return api.clone();
    }
    if let Ok(api) = std::env::var("MJOLNIR_API") {
        if !api.is_empty() {
            return api;
        }
    }
    let config = Config::load();
    config.api.unwrap_or_else(|| DEFAULT_API.to_string())
}

/// Show current config.
pub fn show() {
    let config = Config::load();
    let path = config_path();
    println!("Config:  {}", path.display());
    println!("API:     {}", config.api.as_deref().unwrap_or("(default) http://localhost:4000"));
}

/// Set a config key.
pub fn set(key: &str, value: &str) -> Result<(), Box<dyn std::error::Error>> {
    let mut config = Config::load();
    match key {
        "api" => {
            config.api = Some(value.to_string());
            config.save()?;
            eprintln!("Set api = {}", value);
        }
        _ => return Err(format!("Unknown config key: {}", key).into()),
    }
    Ok(())
}
