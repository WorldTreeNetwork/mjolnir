// SPDX-License-Identifier: AGPL-3.0-or-later
//! IRON Lab occupancy flock. Same identity as ironlab-device occupancy.rs.
//!
//! Lock: `$XDG_RUNTIME_DIR/ironlab/occupancy.lock` (override `AIE_OCCUPANCY_DIR`).
//! State: `occupancy.json` `{pid, bundle, started_unix, exe}`.
//! Worker MUST inherit the flock fd. Dead-pid steal without inherit is no-go.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use nix::fcntl::{flock, FlockArg};
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct OccupancyState {
    pub pid: i32,
    pub bundle: Option<String>,
    pub started_unix: u64,
    pub exe: Option<String>,
}

pub struct OccupancyGuard {
    file: File,
    state: OccupancyState,
    path: PathBuf,
    released: bool,
}

impl OccupancyGuard {
    pub fn raw_fd(&self) -> RawFd {
        self.file.as_raw_fd()
    }

    pub fn state(&self) -> &OccupancyState {
        &self.state
    }

    pub fn release(&mut self) {
        if self.released {
            return;
        }
        let _ = clear_state_if_ours(&self.path, self.state.pid);
        let _ = flock(&self.file, FlockArg::Unlock);
        self.released = true;
    }
}

impl Drop for OccupancyGuard {
    fn drop(&mut self) {
        self.release();
    }
}

#[derive(Debug)]
pub enum TryLockError {
    Occupied { pid: i32, bundle: Option<String>, started_unix: u64 },
    Io(io::Error),
}

impl From<io::Error> for TryLockError {
    fn from(e: io::Error) -> Self {
        TryLockError::Io(e)
    }
}

pub fn occupancy_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("AIE_OCCUPANCY_DIR") {
        return PathBuf::from(dir);
    }
    if let Ok(runtime) = std::env::var("XDG_RUNTIME_DIR") {
        return PathBuf::from(runtime).join("ironlab");
    }
    PathBuf::from(format!("/tmp/ironlab-{}", nix::unistd::Uid::effective().as_raw()))
}

pub fn lock_path() -> PathBuf {
    occupancy_dir().join("occupancy.lock")
}

pub fn state_path() -> PathBuf {
    occupancy_dir().join("occupancy.json")
}

fn pid_alive(pid: i32) -> bool {
    Path::new(&format!("/proc/{pid}")).exists()
}

fn read_state() -> Option<OccupancyState> {
    let path = state_path();
    let text = fs::read_to_string(&path).ok()?;
    if text.trim().is_empty() {
        return None;
    }
    let state: OccupancyState = serde_json::from_str(&text).ok()?;
    if !pid_alive(state.pid) {
        let _ = fs::remove_file(&path);
        return None;
    }
    Some(state)
}

fn write_state(bundle: Option<&str>) -> io::Result<OccupancyState> {
    let exe = fs::read_link("/proc/self/exe")
        .ok()
        .map(|p| p.display().to_string());
    let state = OccupancyState {
        pid: std::process::id() as i32,
        bundle: bundle.map(|s| s.to_string()),
        started_unix: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
        exe,
    };
    let path = state_path();
    let tmp = path.with_extension("json.tmp");
    let mut f = File::create(&tmp)?;
    f.write_all(serde_json::to_string_pretty(&state).unwrap().as_bytes())?;
    f.write_all(b"\n")?;
    f.sync_all()?;
    fs::rename(tmp, path)?;
    Ok(state)
}

fn clear_state_if_ours(path: &Path, pid: i32) -> io::Result<()> {
    if let Ok(text) = fs::read_to_string(path) {
        if let Ok(state) = serde_json::from_str::<OccupancyState>(&text) {
            if state.pid == pid {
                let _ = fs::remove_file(path);
            }
        }
    }
    Ok(())
}

/// Try-lock. Refuses while the flock is held even if occupancy.json pid is dead
/// (orphan worker inherited the fd). Does not take occupancy.rs steal path.
pub fn try_lock(bundle: Option<&str>) -> Result<OccupancyGuard, TryLockError> {
    fs::create_dir_all(occupancy_dir())?;
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(lock_path())?;
    match flock(&file, FlockArg::LockExclusiveNonblock) {
        Ok(()) => {}
        Err(nix::errno::Errno::EWOULDBLOCK | nix::errno::Errno::EAGAIN) => {
            if let Some(state) = read_state() {
                return Err(TryLockError::Occupied {
                    pid: state.pid,
                    bundle: state.bundle,
                    started_unix: state.started_unix,
                });
            }
            return Err(TryLockError::Occupied {
                pid: 0,
                bundle: Some("flock-held-no-live-json".into()),
                started_unix: 0,
            });
        }
        Err(e) => return Err(TryLockError::Io(std::io::Error::from(e))),
    }
    let state = write_state(bundle)?;
    Ok(OccupancyGuard {
        file,
        state,
        path: state_path(),
        released: false,
    })
}

pub fn clear_cloexec(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    let r = unsafe { libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) };
    if r < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
