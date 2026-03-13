//! LUKS secrets volume management.
//!
//! Provides create, open, close, and mount operations for an encrypted
//! LUKS loopback container at `/var/lib/mjolnir/secrets.luks`. Secrets
//! are exposed as environment variables via `/etc/mjolnir/secrets.env`.

use std::collections::HashMap;
use std::path::Path;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use tracing::{error, info, warn};

pub const SECRETS_LUKS_PATH: &str = "/var/lib/mjolnir/secrets.luks";
pub const SECRETS_MOUNT: &str = "/secrets";
pub const SECRETS_MAPPER_NAME: &str = "mjolnir-secrets";
pub const SECRETS_ENV_PATH: &str = "/etc/mjolnir/secrets.env";
pub const SECRETS_PROFILE_PATH: &str = "/etc/profile.d/mjolnir-secrets.sh";
pub const DEFAULT_SECRETS_SIZE_MB: u32 = 32;

/// One-shot guard: once secrets have been injected, reject further inject attempts.
static SECRETS_INJECTED: AtomicBool = AtomicBool::new(false);

/// Check if secrets have already been injected this session.
pub fn is_injected() -> bool {
    SECRETS_INJECTED.load(Ordering::SeqCst)
}

/// Mark secrets as injected (one-shot guard).
pub fn mark_injected() {
    SECRETS_INJECTED.store(true, Ordering::SeqCst);
}

/// Check if the secrets volume is currently mounted.
pub fn is_mounted() -> bool {
    Path::new("/dev/mapper").join(SECRETS_MAPPER_NAME).exists()
}

/// Check if cryptsetup is available in the guest.
pub fn check_cryptsetup() -> Result<(), String> {
    match Command::new("which").arg("cryptsetup").output() {
        Ok(out) if out.status.success() => Ok(()),
        _ => Err("cryptsetup not found in guest image".to_string()),
    }
}

/// Create a new LUKS secrets volume, format it, and mount it.
///
/// This is idempotent for the "already exists" case (returns error).
pub fn init_secrets_volume(size_mb: u32, passphrase: &str) -> Result<InitResult, String> {
    let path = Path::new(SECRETS_LUKS_PATH);

    if path.exists() {
        return Err("secrets.luks already exists — use open instead of init".to_string());
    }

    check_cryptsetup()?;

    info!("Creating secrets volume: {}MB", size_mb);

    // Ensure parent directory exists
    if let Some(parent) = Path::new(SECRETS_LUKS_PATH).parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create {}: {}", parent.display(), e))?;
    }

    // Create the backing file
    run_cmd("dd", &[
        "if=/dev/zero",
        &format!("of={}", SECRETS_LUKS_PATH),
        "bs=1M",
        &format!("count={}", size_mb),
    ])?;

    // Set up loop device
    let loop_dev = setup_loop_device(SECRETS_LUKS_PATH)?;
    info!("Loop device: {}", loop_dev);

    // LUKS format with passphrase via keyfile (stdin)
    let result = (|| -> Result<(), String> {
        luks_format(&loop_dev, passphrase)?;
        info!("LUKS formatted");

        luks_open(&loop_dev, passphrase)?;
        info!("LUKS opened");

        // Format ext4
        run_cmd("mkfs.ext4", &["-q", &format!("/dev/mapper/{}", SECRETS_MAPPER_NAME)])?;
        info!("ext4 formatted");

        // Mount
        std::fs::create_dir_all(SECRETS_MOUNT)
            .map_err(|e| format!("Failed to create mount point: {}", e))?;
        run_cmd("mount", &[
            &format!("/dev/mapper/{}", SECRETS_MAPPER_NAME),
            SECRETS_MOUNT,
        ])?;
        info!("Mounted at {}", SECRETS_MOUNT);

        // Create directory structure
        create_secrets_dirs()?;

        Ok(())
    })();

    if let Err(e) = &result {
        // Cleanup on failure
        error!("Init failed, cleaning up: {}", e);
        let _ = cleanup_luks(&loop_dev);
        let _ = std::fs::remove_file(SECRETS_LUKS_PATH);
        return Err(e.clone());
    }

    Ok(InitResult { created: true, mounted: true })
}

/// Open and mount an existing LUKS secrets volume.
pub fn open_secrets_volume(passphrase: &str) -> Result<(), String> {
    if is_mounted() {
        info!("Secrets volume already mounted");
        return Ok(());
    }

    let path = Path::new(SECRETS_LUKS_PATH);
    if !path.exists() {
        return Err("secrets.luks does not exist — use init first".to_string());
    }

    check_cryptsetup()?;

    let loop_dev = setup_loop_device(SECRETS_LUKS_PATH)?;
    info!("Loop device: {}", loop_dev);

    luks_open(&loop_dev, passphrase)?;
    info!("LUKS opened");

    std::fs::create_dir_all(SECRETS_MOUNT)
        .map_err(|e| format!("Failed to create mount point: {}", e))?;
    run_cmd("mount", &[
        &format!("/dev/mapper/{}", SECRETS_MAPPER_NAME),
        SECRETS_MOUNT,
    ])?;
    info!("Mounted at {}", SECRETS_MOUNT);

    Ok(())
}

/// Close the LUKS secrets volume: unmount, close LUKS, detach loop.
pub fn close_secrets_volume() -> Result<(), String> {
    if !is_mounted() {
        return Ok(());
    }

    // Unmount
    let _ = run_cmd("umount", &[SECRETS_MOUNT]);

    // Close LUKS
    let _ = run_cmd("cryptsetup", &["luksClose", SECRETS_MAPPER_NAME]);

    // Find and detach the loop device
    if let Ok(loop_dev) = find_loop_for_file(SECRETS_LUKS_PATH) {
        let _ = run_cmd("losetup", &["-d", &loop_dev]);
    }

    info!("Secrets volume closed");
    Ok(())
}

/// Parse .env files from the secrets mount and write to /etc/mjolnir/secrets.env.
///
/// Format: `export KEY=VALUE` (one per line), shell-safe quoting.
pub fn load_env_vars() -> Result<HashMap<String, String>, String> {
    let env_file = Path::new(SECRETS_MOUNT).join(".env");
    let mut vars = HashMap::new();

    // Parse main .env file
    if env_file.exists() {
        let content = std::fs::read_to_string(&env_file)
            .map_err(|e| format!("Failed to read .env: {}", e))?;
        parse_env_into(&content, &mut vars);
    }

    // Parse env.d/*.env files
    let env_d = Path::new(SECRETS_MOUNT).join("env.d");
    if env_d.is_dir() {
        if let Ok(entries) = std::fs::read_dir(&env_d) {
            let mut files: Vec<_> = entries
                .filter_map(|e| e.ok())
                .filter(|e| e.path().extension().map_or(false, |ext| ext == "env"))
                .collect();
            files.sort_by_key(|e| e.file_name());
            for entry in files {
                if let Ok(content) = std::fs::read_to_string(entry.path()) {
                    parse_env_into(&content, &mut vars);
                }
            }
        }
    }

    // Write /etc/mjolnir/secrets.env
    write_secrets_env(&vars)?;

    // Write /etc/profile.d/mjolnir-secrets.sh for interactive shells
    write_profile_source()?;

    info!("Loaded {} env vars from secrets volume", vars.len());
    Ok(vars)
}

/// Set specific env vars in the secrets .env file.
pub fn set_env_vars(entries: &HashMap<String, String>) -> Result<(), String> {
    if !is_mounted() {
        return Err("Secrets volume not mounted".to_string());
    }

    let env_file = Path::new(SECRETS_MOUNT).join(".env");

    // Read existing vars
    let mut vars = HashMap::new();
    if env_file.exists() {
        let content = std::fs::read_to_string(&env_file)
            .map_err(|e| format!("Failed to read .env: {}", e))?;
        parse_env_into(&content, &mut vars);
    }

    // Merge new entries
    for (k, v) in entries {
        vars.insert(k.clone(), v.clone());
    }

    // Write back to .env
    let mut lines: Vec<String> = vars.iter()
        .map(|(k, v)| format!("{}={}", k, v))
        .collect();
    lines.sort();
    let content = lines.join("\n") + "\n";
    std::fs::write(&env_file, content)
        .map_err(|e| format!("Failed to write .env: {}", e))?;

    // Reload
    load_env_vars()?;
    Ok(())
}

/// Push raw .env content into the secrets volume.
pub fn push_env_content(content: &str) -> Result<(), String> {
    if !is_mounted() {
        return Err("Secrets volume not mounted".to_string());
    }

    let env_file = Path::new(SECRETS_MOUNT).join(".env");
    std::fs::write(&env_file, content)
        .map_err(|e| format!("Failed to write .env: {}", e))?;

    load_env_vars()?;
    Ok(())
}

// ============================================================================
// Internal helpers
// ============================================================================

pub struct InitResult {
    pub created: bool,
    pub mounted: bool,
}

fn run_cmd(program: &str, args: &[&str]) -> Result<String, String> {
    let output = Command::new(program)
        .args(args)
        .output()
        .map_err(|e| format!("Failed to run {}: {}", program, e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        return Err(format!(
            "{} failed (exit {}): {} {}",
            program,
            output.status.code().unwrap_or(-1),
            stderr.trim(),
            stdout.trim()
        ));
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn setup_loop_device(file_path: &str) -> Result<String, String> {
    run_cmd("losetup", &["--find", "--show", file_path])
}

fn find_loop_for_file(file_path: &str) -> Result<String, String> {
    let output = run_cmd("losetup", &["-j", file_path])?;
    // Output format: /dev/loop0: [0019]:12345 (/path/to/file)
    output
        .split(':')
        .next()
        .map(|s| s.trim().to_string())
        .ok_or_else(|| "No loop device found".to_string())
}

fn luks_format(loop_dev: &str, passphrase: &str) -> Result<(), String> {
    // Write passphrase to a temporary keyfile (deleted immediately after)
    let keyfile = "/tmp/.mjolnir-keyfile";
    std::fs::write(keyfile, passphrase)
        .map_err(|e| format!("Failed to write keyfile: {}", e))?;

    let result = run_cmd("cryptsetup", &[
        "luksFormat",
        "--batch-mode",
        "--key-file", keyfile,
        loop_dev,
    ]);

    // Always clean up the keyfile
    let _ = std::fs::remove_file(keyfile);

    result.map(|_| ())
}

fn luks_open(loop_dev: &str, passphrase: &str) -> Result<(), String> {
    let keyfile = "/tmp/.mjolnir-keyfile";
    std::fs::write(keyfile, passphrase)
        .map_err(|e| format!("Failed to write keyfile: {}", e))?;

    let result = run_cmd("cryptsetup", &[
        "luksOpen",
        "--key-file", keyfile,
        loop_dev,
        SECRETS_MAPPER_NAME,
    ]);

    let _ = std::fs::remove_file(keyfile);

    result.map(|_| ())
}

fn cleanup_luks(loop_dev: &str) -> Result<(), String> {
    let _ = run_cmd("umount", &[SECRETS_MOUNT]);
    let _ = run_cmd("cryptsetup", &["luksClose", SECRETS_MAPPER_NAME]);
    let _ = run_cmd("losetup", &["-d", loop_dev]);
    Ok(())
}

fn create_secrets_dirs() -> Result<(), String> {
    let dirs = [
        format!("{}/env.d", SECRETS_MOUNT),
        format!("{}/files", SECRETS_MOUNT),
    ];
    for dir in &dirs {
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("Failed to create {}: {}", dir, e))?;
    }

    // Create empty .env file
    let env_path = format!("{}/.env", SECRETS_MOUNT);
    if !Path::new(&env_path).exists() {
        std::fs::write(&env_path, "# Mjolnir Secrets\n# KEY=VALUE\n")
            .map_err(|e| format!("Failed to create .env: {}", e))?;
    }

    // Create metadata.json
    let meta_path = format!("{}/metadata.json", SECRETS_MOUNT);
    if !Path::new(&meta_path).exists() {
        let meta = serde_json::json!({
            "version": 1,
            "created_at": chrono_now_iso(),
        });
        std::fs::write(&meta_path, serde_json::to_string_pretty(&meta).unwrap())
            .map_err(|e| format!("Failed to create metadata.json: {}", e))?;
    }

    Ok(())
}

/// Parse KEY=VALUE lines from .env content. Skips comments (#) and blank lines.
/// Handles simple quoting (double/single quotes around values).
pub fn parse_env_into(content: &str, vars: &mut HashMap<String, String>) {
    for line in content.lines() {
        let trimmed = line.trim();

        // Skip empty lines and comments
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        // Split on first '='
        if let Some(eq_pos) = trimmed.find('=') {
            let key = trimmed[..eq_pos].trim().to_string();
            let mut value = trimmed[eq_pos + 1..].trim().to_string();

            // Strip surrounding quotes
            if (value.starts_with('"') && value.ends_with('"'))
                || (value.starts_with('\'') && value.ends_with('\''))
            {
                value = value[1..value.len() - 1].to_string();
            }

            if !key.is_empty() {
                vars.insert(key, value);
            }
        }
    }
}

fn write_secrets_env(vars: &HashMap<String, String>) -> Result<(), String> {
    // Ensure /etc/mjolnir exists
    std::fs::create_dir_all("/etc/mjolnir")
        .map_err(|e| format!("Failed to create /etc/mjolnir: {}", e))?;

    let mut lines: Vec<String> = vars
        .iter()
        .map(|(k, v)| format!("export {}='{}'", k, v.replace('\'', "'\\''")))
        .collect();
    lines.sort();

    let content = if lines.is_empty() {
        "# No secrets configured\n".to_string()
    } else {
        lines.join("\n") + "\n"
    };

    std::fs::write(SECRETS_ENV_PATH, content)
        .map_err(|e| format!("Failed to write {}: {}", SECRETS_ENV_PATH, e))?;

    info!("Wrote {} vars to {}", vars.len(), SECRETS_ENV_PATH);
    Ok(())
}

fn write_profile_source() -> Result<(), String> {
    let content = format!(
        "# Mjolnir secrets — auto-generated, do not edit\n\
         [ -f {} ] && . {}\n",
        SECRETS_ENV_PATH, SECRETS_ENV_PATH
    );

    std::fs::write(SECRETS_PROFILE_PATH, content)
        .map_err(|e| format!("Failed to write {}: {}", SECRETS_PROFILE_PATH, e))?;

    Ok(())
}

fn chrono_now_iso() -> String {
    // Simple ISO timestamp without pulling in chrono crate
    use std::time::SystemTime;
    let duration = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}Z", duration.as_secs())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_env_basic() {
        let mut vars = HashMap::new();
        parse_env_into("FOO=bar\nBAZ=qux\n", &mut vars);
        assert_eq!(vars.get("FOO"), Some(&"bar".to_string()));
        assert_eq!(vars.get("BAZ"), Some(&"qux".to_string()));
    }

    #[test]
    fn test_parse_env_comments_and_blanks() {
        let mut vars = HashMap::new();
        parse_env_into("# comment\n\nFOO=bar\n  # another\n", &mut vars);
        assert_eq!(vars.len(), 1);
        assert_eq!(vars.get("FOO"), Some(&"bar".to_string()));
    }

    #[test]
    fn test_parse_env_quoted_values() {
        let mut vars = HashMap::new();
        parse_env_into(
            "DOUBLE=\"hello world\"\nSINGLE='foo bar'\nNOQUOTE=plain\n",
            &mut vars,
        );
        assert_eq!(vars.get("DOUBLE"), Some(&"hello world".to_string()));
        assert_eq!(vars.get("SINGLE"), Some(&"foo bar".to_string()));
        assert_eq!(vars.get("NOQUOTE"), Some(&"plain".to_string()));
    }

    #[test]
    fn test_parse_env_value_with_equals() {
        let mut vars = HashMap::new();
        parse_env_into("URL=postgres://host:5432/db?ssl=true\n", &mut vars);
        assert_eq!(
            vars.get("URL"),
            Some(&"postgres://host:5432/db?ssl=true".to_string())
        );
    }

    #[test]
    fn test_parse_env_empty_value() {
        let mut vars = HashMap::new();
        parse_env_into("EMPTY=\n", &mut vars);
        assert_eq!(vars.get("EMPTY"), Some(&"".to_string()));
    }

    #[test]
    fn test_parse_env_overwrites() {
        let mut vars = HashMap::new();
        parse_env_into("KEY=first\nKEY=second\n", &mut vars);
        assert_eq!(vars.get("KEY"), Some(&"second".to_string()));
    }
}
