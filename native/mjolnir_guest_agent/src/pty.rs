//! PTY allocation and management using nix.

use nix::pty::{openpty, OpenptyResult, Winsize};
use nix::sys::signal::{kill, Signal};
use nix::sys::wait::{waitpid, WaitPidFlag, WaitStatus};
use nix::unistd::{dup2, execvp, fork, setsid, ForkResult, Pid};
use std::ffi::CString;
use std::os::unix::io::{AsRawFd, FromRawFd, IntoRawFd};
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub struct PtySession {
    master_read: File,
    master_write: File,
    master_fd: i32,
    child_pid: Pid,
    exit_code: Option<i32>,
}

impl PtySession {
    /// Spawn a new PTY session running the given command.
    pub fn spawn(
        cmd: &str,
        cols: u16,
        rows: u16,
    ) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let winsize = Winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };

        // Open PTY pair
        let OpenptyResult { master, slave } = openpty(&winsize, None)?;

        // Fork
        match unsafe { fork()? } {
            ForkResult::Parent { child } => {
                // Close slave in parent
                drop(slave);

                let raw_fd = master.as_raw_fd();

                // Dup the master fd so we have separate read/write handles.
                // This avoids deadlocks when reading output and writing input
                // happen concurrently from different tasks.
                let write_fd = unsafe { libc::dup(raw_fd) };
                if write_fd < 0 {
                    return Err(std::io::Error::last_os_error().into());
                }

                let master_read = unsafe { File::from_raw_fd(master.into_raw_fd()) };
                let master_write = unsafe { File::from_raw_fd(write_fd) };

                Ok(Self {
                    master_fd: raw_fd,
                    master_read,
                    master_write,
                    child_pid: child,
                    exit_code: None,
                })
            }
            ForkResult::Child => {
                // Close master in child
                drop(master);

                // Create new session
                setsid().ok();

                // Set controlling terminal
                let slave_fd = slave.as_raw_fd();
                unsafe {
                    libc::ioctl(slave_fd, libc::TIOCSCTTY, 0);
                }

                // Dup slave to stdin/stdout/stderr
                dup2(slave_fd, 0).ok();
                dup2(slave_fd, 1).ok();
                dup2(slave_fd, 2).ok();

                if slave_fd > 2 {
                    drop(slave);
                }

                // Exec shell
                let cmd_cstr = CString::new(cmd).unwrap();
                let args = [cmd_cstr.clone()];
                execvp(&cmd_cstr, &args).ok();

                // If exec fails, exit
                std::process::exit(127);
            }
        }
    }

    /// Split the session into a reader (for output) and the rest (for input/resize).
    /// The reader can be used independently without holding any lock on the session.
    /// Uses ManuallyDrop to suppress PtySession's Drop (PtyWriter's Drop handles cleanup).
    pub fn into_split(self) -> (PtyReader, PtyWriter) {
        let mut this = std::mem::ManuallyDrop::new(self);
        unsafe {
            let master_read = std::ptr::read(&this.master_read);
            let master_write = std::ptr::read(&this.master_write);
            (
                PtyReader { master_read },
                PtyWriter {
                    master_write,
                    master_fd: this.master_fd,
                    child_pid: this.child_pid,
                    exit_code: this.exit_code,
                },
            )
        }
    }

    /// Write data to PTY stdin.
    pub async fn write_all(&mut self, data: &[u8]) -> std::io::Result<()> {
        self.master_write.write_all(data).await
    }

    /// Read data from PTY stdout.
    pub async fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.master_read.read(buf).await
    }

    /// Resize the PTY window.
    pub fn resize(
        &self,
        rows: u16,
        cols: u16,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let winsize = Winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        unsafe {
            if libc::ioctl(self.master_fd, libc::TIOCSWINSZ, &winsize) < 0 {
                return Err("ioctl TIOCSWINSZ failed".into());
            }
        }
        kill(self.child_pid, Signal::SIGWINCH).ok();
        Ok(())
    }

    /// Check if child process has exited (non-blocking).
    pub fn try_wait(&mut self) -> Option<i32> {
        match waitpid(self.child_pid, Some(WaitPidFlag::WNOHANG)) {
            Ok(WaitStatus::Exited(_, code)) => {
                self.exit_code = Some(code);
                Some(code)
            }
            Ok(WaitStatus::Signaled(_, sig, _)) => {
                let code = 128 + sig as i32;
                self.exit_code = Some(code);
                Some(code)
            }
            _ => None,
        }
    }

    /// Get exit code if process has exited.
    #[allow(dead_code)]
    pub fn exit_code(&self) -> Option<i32> {
        self.exit_code
    }

    /// Wait for exit code (polling with sleep).
    pub async fn wait_exit_code(&mut self) -> i32 {
        loop {
            if let Some(code) = self.try_wait() {
                return code;
            }
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        }
    }

    /// Get the child PID.
    #[allow(dead_code)]
    pub fn pid(&self) -> Pid {
        self.child_pid
    }
}

/// Read half of a PTY session — owns the master read fd.
/// Can be used independently from a separate task without locks.
pub struct PtyReader {
    master_read: File,
}

impl PtyReader {
    pub async fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.master_read.read(buf).await
    }
}

/// Write half of a PTY session — owns the master write fd, child PID, and resize.
pub struct PtyWriter {
    master_write: File,
    master_fd: i32,
    child_pid: Pid,
    exit_code: Option<i32>,
}

impl PtyWriter {
    pub async fn write_all(&mut self, data: &[u8]) -> std::io::Result<()> {
        self.master_write.write_all(data).await
    }

    pub fn resize(
        &self,
        rows: u16,
        cols: u16,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let winsize = Winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        unsafe {
            if libc::ioctl(self.master_fd, libc::TIOCSWINSZ, &winsize) < 0 {
                return Err("ioctl TIOCSWINSZ failed".into());
            }
        }
        kill(self.child_pid, Signal::SIGWINCH).ok();
        Ok(())
    }
}

impl Drop for PtyWriter {
    fn drop(&mut self) {
        let _ = kill(self.child_pid, Signal::SIGTERM);
    }
}

impl Drop for PtySession {
    fn drop(&mut self) {
        // Kill child process if still running
        let _ = kill(self.child_pid, Signal::SIGTERM);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_pty_echo() {
        let mut pty = PtySession::spawn("/bin/cat", 80, 24).unwrap();

        // Write some data
        pty.write_all(b"hello\n").await.unwrap();

        // Give cat time to echo
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        // Read it back
        let mut buf = [0u8; 64];
        let n = pty.read(&mut buf).await.unwrap();
        let output = String::from_utf8_lossy(&buf[..n]);

        assert!(output.contains("hello"), "Expected 'hello' in output: {}", output);
    }

    #[tokio::test]
    async fn test_pty_exit_code() {
        let mut pty = PtySession::spawn("/bin/true", 80, 24).unwrap();
        let code = pty.wait_exit_code().await;
        assert_eq!(code, 0);
    }

    #[tokio::test]
    async fn test_pty_exit_code_failure() {
        let mut pty = PtySession::spawn("/bin/false", 80, 24).unwrap();
        let code = pty.wait_exit_code().await;
        assert_eq!(code, 1);
    }
}
