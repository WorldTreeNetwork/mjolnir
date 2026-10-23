//! Step guest wall time after a memory-snapshot restore.
//!
//! A Cloud Hypervisor `vm.restore` brings vCPUs back on the KVM clock that
//! was saved at snapshot time (CH #7932 restores that clock; it does not
//! advance it by the park). The host REST API this stack speaks has no
//! endpoint that writes the KVM clock while the VM is still paused, so the
//! step happens here, after `vm.resume`, and the host refuses to publish the
//! VM until this call confirms.
//!
//! Only `CLOCK_REALTIME` is written. `CLOCK_MONOTONIC` is not a settable
//! clock and must not jump by the park: a days-long freeze is not suspend
//! time. `CLOCK_BOOTTIME` is likewise left alone — injecting sleeptime into
//! it is what laptop hibernate does inside the kernel, and userspace
//! `clock_settime` cannot do that.
//!
//! Processes already running inside the guest can observe the snapshot clock
//! in the window between `vm.resume` and this call. The host gate closes
//! that window for everyone outside the guest. It does not rewind it for
//! processes that were frozen mid-syscall.

use std::io;

/// The only clock this module writes. Tests pin the list so a later edit
/// cannot quietly add `CLOCK_MONOTONIC` or `CLOCK_BOOTTIME`.
pub fn clocks_written() -> [libc::clockid_t; 1] {
    [libc::CLOCK_REALTIME]
}

/// Reject a host timestamp this agent will not apply.
///
/// `nsec` must be a real fractional second. A negative unix time is refused
/// so a confused host cannot roll the guest into the pre-epoch.
pub fn validate(secs: i64, nsec: i64) -> Result<(), String> {
    if secs < 0 {
        return Err("realtime before the unix epoch".into());
    }
    if !(0..1_000_000_000).contains(&nsec) {
        return Err("realtime_nsec out of range".into());
    }
    Ok(())
}

#[derive(Debug)]
pub struct WallOutcome {
    pub ok: bool,
    /// `CLOCK_REALTIME` read back after the set, or 0 when the set failed.
    pub realtime_secs: i64,
    /// Always false. There is no code path that steps monotonic time.
    pub monotonic_stepped: bool,
    pub error: Option<String>,
}

/// Set `CLOCK_REALTIME` to `secs` + `nsec` and read it back.
///
/// Requires `CAP_SYS_TIME`. The agent runs as root inside the guest. A
/// failure is `ok: false` — the host then leaves the thaw unpublished.
pub fn apply_wall(secs: i64, nsec: i64) -> WallOutcome {
    if let Err(error) = validate(secs, nsec) {
        return WallOutcome {
            ok: false,
            realtime_secs: 0,
            monotonic_stepped: false,
            error: Some(error),
        };
    }

    for id in clocks_written() {
        let ts = libc::timespec {
            tv_sec: secs as libc::time_t,
            tv_nsec: nsec as libc::c_long,
        };
        let rc = unsafe { libc::clock_settime(id, &ts) };
        if rc != 0 {
            return WallOutcome {
                ok: false,
                realtime_secs: 0,
                monotonic_stepped: false,
                error: Some(format!(
                    "clock_settime(CLOCK_REALTIME) failed: {}",
                    io::Error::last_os_error()
                )),
            };
        }
    }

    let mut now = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    let rc = unsafe { libc::clock_gettime(libc::CLOCK_REALTIME, &mut now) };
    if rc != 0 {
        return WallOutcome {
            ok: false,
            realtime_secs: 0,
            monotonic_stepped: false,
            error: Some(format!(
                "clock_gettime(CLOCK_REALTIME) failed: {}",
                io::Error::last_os_error()
            )),
        };
    }

    let readback = now.tv_sec as i64;
    if (readback - secs).abs() > 2 {
        return WallOutcome {
            ok: false,
            realtime_secs: readback,
            monotonic_stepped: false,
            error: Some(format!(
                "wall clock read back {readback}, host asked for {secs}"
            )),
        };
    }

    WallOutcome {
        ok: true,
        realtime_secs: readback,
        monotonic_stepped: false,
        error: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_realtime_and_nothing_else() {
        let clocks = clocks_written();
        assert_eq!(clocks, [libc::CLOCK_REALTIME]);
        assert!(!clocks.contains(&libc::CLOCK_MONOTONIC));
        assert!(!clocks.contains(&libc::CLOCK_MONOTONIC_RAW));
        assert!(!clocks.contains(&libc::CLOCK_BOOTTIME));
    }

    #[test]
    fn rejects_a_pre_epoch_or_bogus_fraction_without_setting_anything() {
        assert!(validate(-1, 0).is_err());
        assert!(validate(1_700_000_000, -1).is_err());
        assert!(validate(1_700_000_000, 1_000_000_000).is_err());
        assert!(validate(1_700_000_000, 0).is_ok());

        let outcome = apply_wall(1_700_000_000, 1_000_000_000);
        assert!(!outcome.ok);
        assert!(!outcome.monotonic_stepped);
        assert_eq!(outcome.realtime_secs, 0);
    }
}
