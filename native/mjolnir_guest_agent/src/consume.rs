//! Default mailbox consume loop (mjolnir-axsb.5.2).
//!
//! Peek the in-guest inbox, fsync the producer id, dispatch the payload,
//! then application-ACK. HTTP peek/ack stay; this loop is extra.

use std::collections::HashSet;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use serde_json::Value;
use tracing::{info, warn};

const DEFAULT_SEEN: &str = "/var/lib/mjolnir/mail-seen";
const DEFAULT_DROP: &str = "/var/lib/mjolnir/mail";
const DEFAULT_HOOK: &str = "/var/lib/agent/on-mail";

#[derive(Debug, Clone)]
pub struct MailItem {
    pub id: String,
    pub from_vm_id: String,
    pub payload: Value,
}

pub struct SeenStore {
    path: PathBuf,
    ids: HashSet<String>,
}

impl SeenStore {
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let path = path.as_ref().to_path_buf();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let ids = if path.exists() {
            std::fs::read_to_string(&path)?
                .lines()
                .filter(|l| !l.is_empty())
                .map(|l| l.to_string())
                .collect()
        } else {
            HashSet::new()
        };
        Ok(Self { path, ids })
    }

    pub fn contains(&self, id: &str) -> bool {
        self.ids.contains(id)
    }

    /// Append + fsync. Idempotent if already present.
    pub fn record(&mut self, id: &str) -> io::Result<()> {
        if self.ids.contains(id) {
            return Ok(());
        }
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        file.write_all(id.as_bytes())?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        if let Some(dir) = self.path.parent() {
            let dirf = std::fs::File::open(dir)?;
            dirf.sync_all()?;
        }
        self.ids.insert(id.to_string());
        Ok(())
    }
}

pub fn consume_enabled() -> bool {
    match std::env::var("MJOLNIR_MAIL_CONSUME") {
        Ok(v) if v == "0" || v.eq_ignore_ascii_case("false") => false,
        _ => true,
    }
}

pub fn seen_path() -> PathBuf {
    std::env::var("MJOLNIR_MAIL_SEEN")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(DEFAULT_SEEN))
}

pub fn drop_dir() -> PathBuf {
    std::env::var("MJOLNIR_MAIL_DROP")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(DEFAULT_DROP))
}

pub fn hook_path() -> PathBuf {
    std::env::var("MJOLNIR_MAIL_HOOK")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(DEFAULT_HOOK))
}

/// Write the payload next to the seen file, then run an optional hook.
/// Returns whether this id was newly recorded (first delivery).
pub fn record_and_dispatch(seen: &mut SeenStore, item: &MailItem, drop: &Path) -> io::Result<bool> {
    let fresh = !seen.contains(&item.id);
    seen.record(&item.id)?;
    if !fresh {
        return Ok(false);
    }
    std::fs::create_dir_all(drop)?;
    let path = drop.join(format!("{}.json", sanitize_id(&item.id)));
    let body = serde_json::json!({
        "id": item.id,
        "from_vm_id": item.from_vm_id,
        "payload": item.payload
    });
    let tmp = path.with_extension("json.tmp");
    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(body.to_string().as_bytes())?;
        f.sync_all()?;
    }
    std::fs::rename(&tmp, &path)?;
    run_hook(&path);
    Ok(true)
}

fn sanitize_id(id: &str) -> String {
    id.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

fn run_hook(mail_path: &Path) {
    let hook = hook_path();
    if !hook.is_file() {
        return;
    }
    match std::process::Command::new(&hook).arg(mail_path).status() {
        Ok(st) if st.success() => info!(hook = %hook.display(), "on-mail hook ok"),
        Ok(st) => warn!(hook = %hook.display(), code = ?st.code(), "on-mail hook failed"),
        Err(e) => warn!(hook = %hook.display(), error = %e, "on-mail hook exec"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp() -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "mj-mail-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn record_is_idempotent_and_survives_reopen() {
        let dir = tmp();
        let seen_path = dir.join("seen");
        let drop = dir.join("drop");
        let item = MailItem {
            id: "turn-1".into(),
            from_vm_id: "papyrus".into(),
            payload: serde_json::json!({"type": "turn"}),
        };
        {
            let mut seen = SeenStore::open(&seen_path).unwrap();
            assert!(record_and_dispatch(&mut seen, &item, &drop).unwrap());
            assert!(!record_and_dispatch(&mut seen, &item, &drop).unwrap());
        }
        let seen = SeenStore::open(&seen_path).unwrap();
        assert!(seen.contains("turn-1"));
        assert!(drop.join("turn-1.json").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn crash_before_record_leaves_id_unseen() {
        let dir = tmp();
        let seen = SeenStore::open(dir.join("seen")).unwrap();
        assert!(!seen.contains("turn-2"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
