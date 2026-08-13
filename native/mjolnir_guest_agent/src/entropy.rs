//! Reseeding the guest CRNG after a memory-snapshot restore.
//!
//! # Why this exists
//!
//! Restoring one memory snapshot twice yields two guests with *identical* CRNG
//! state. They go on to generate the same session keys, the same TLS nonces,
//! the same UUIDs. This is the classic VM-snapshot cloning vulnerability, and
//! it is a real key-compromise path rather than a theoretical one. It gets
//! worse, not better, as freeze/thaw becomes useful: thawing once and
//! discarding is mild, but *forking N VMs from one image* — a feature we
//! explicitly want — hands every fork the same random stream.
//!
//! # Why a write to /dev/urandom is not enough
//!
//! Writing bytes to `/dev/urandom` mixes them into the pool but **credits zero
//! entropy**. The kernel's estimate of how much unpredictability it holds does
//! not move, and `getrandom(2)`/`/dev/random` consumers are not told anything
//! changed. `RNDADDENTROPY` is the ioctl that both mixes *and* credits, which
//! is what actually forces the CRNG forward.
//!
//! # What this is not
//!
//! The correct mechanism is VMGENID: an ACPI device holding a 128-bit
//! generation ID the hypervisor changes on restore, which Linux's
//! `drivers/virt/vmgenid.c` (5.18+) notices and acts on by reseeding the CRNG
//! **in the kernel, before any userspace task is scheduled**. No userspace
//! reseed can offer that ordering guarantee. Neither half exists on this stack
//! yet — our PVH kernel is built without `CONFIG_VMGENID` and Cloud Hypervisor
//! does not emit the device (mjolnir-3y6.13).
//!
//! So this is the honest interim: vCPUs resume all at once, so the agent
//! cannot beat every other userspace process to the first random byte. The
//! residual race is real and unavoidable without VMGENID. What makes it
//! tolerable is the *host-side gate* — Mjolnir keeps a thawed VM unreachable
//! (no PTY, no ticket, no network exposure) until the agent confirms the
//! reseed, so the exposure is narrowed to processes already inside the guest
//! and cannot be induced by an outside caller.

use serde::{Deserialize, Serialize};
use std::fs::OpenOptions;
use std::io;
use std::os::unix::io::AsRawFd;

/// `RNDADDENTROPY` from `<linux/random.h>`.
///
/// `_IOW('R', 0x03, int[2])` — direction write, type 'R', number 3, size 8.
/// Encoded literally rather than via a macro crate to keep the agent's
/// dependency surface unchanged.
///
/// Typed as `libc::Ioctl` rather than a concrete integer: glibc types the
/// request argument as `c_ulong` while musl types it as `c_int`, and this
/// agent is cross-compiled to `x86_64-unknown-linux-musl`. Hard-coding either
/// one compiles on exactly one of the two targets.
const RNDADDENTROPY: libc::Ioctl = 0x4008_5203;

/// Upper bound on accepted seed material, so a malformed or hostile host
/// message cannot make the guest allocate without limit. 256 bytes is far more
/// than the 32 that meaningfully reseeds a CRNG.
const MAX_SEED_BYTES: usize = 256;

#[derive(Debug, Serialize, Deserialize)]
pub struct ReseedOutcome {
    pub ok: bool,
    /// Bytes actually mixed and credited.
    pub bytes: usize,
    pub error: Option<String>,
}

/// Mix `seed` into the kernel entropy pool and credit it as full-strength
/// entropy.
///
/// The ioctl takes a `rand_pool_info`: two `c_int`s (`entropy_count` in
/// **bits**, `buf_size` in bytes) followed by the payload inline. We build
/// that layout by hand in a byte buffer because the struct is variable-length
/// and has no stable Rust binding.
///
/// Requires `CAP_SYS_ADMIN`; the agent runs as root inside the guest.
pub fn reseed(seed: &[u8]) -> ReseedOutcome {
    if seed.is_empty() {
        return ReseedOutcome {
            ok: false,
            bytes: 0,
            error: Some("empty seed".to_string()),
        };
    }

    if seed.len() > MAX_SEED_BYTES {
        return ReseedOutcome {
            ok: false,
            bytes: 0,
            error: Some(format!(
                "seed of {} bytes exceeds maximum {}",
                seed.len(),
                MAX_SEED_BYTES
            )),
        };
    }

    match add_entropy(seed) {
        Ok(()) => ReseedOutcome {
            ok: true,
            bytes: seed.len(),
            error: None,
        },
        Err(e) => ReseedOutcome {
            ok: false,
            bytes: 0,
            error: Some(format!("RNDADDENTROPY failed: {}", e)),
        },
    }
}

fn add_entropy(seed: &[u8]) -> io::Result<()> {
    // /dev/random, not /dev/urandom: RNDADDENTROPY is served by the random
    // char device, and crediting entropy is the whole point of using it.
    let file = OpenOptions::new().write(true).open("/dev/random")?;

    let mut pool_info = Vec::with_capacity(8 + seed.len());
    // entropy_count is in BITS. Crediting 8 bits per byte claims the host sent
    // full-strength randomness, which it did — the bytes come from the host's
    // already-seeded CSPRNG.
    let entropy_bits = (seed.len() * 8) as libc::c_int;
    pool_info.extend_from_slice(&entropy_bits.to_ne_bytes());
    pool_info.extend_from_slice(&(seed.len() as libc::c_int).to_ne_bytes());
    pool_info.extend_from_slice(seed);

    // SAFETY: pool_info is a live, correctly-sized rand_pool_info for the
    // duration of the call, and `file` owns a valid fd.
    let rc = unsafe {
        libc::ioctl(
            file.as_raw_fd(),
            RNDADDENTROPY,
            pool_info.as_ptr() as *const libc::c_void,
        )
    };

    if rc < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_an_empty_seed() {
        let out = reseed(&[]);
        assert!(!out.ok);
        assert_eq!(out.bytes, 0);
        assert!(out.error.unwrap().contains("empty"));
    }

    #[test]
    fn rejects_an_oversized_seed() {
        // Bounded before any syscall, so this is meaningful even off-guest.
        let out = reseed(&vec![0u8; MAX_SEED_BYTES + 1]);
        assert!(!out.ok);
        assert!(out.error.unwrap().contains("exceeds maximum"));
    }

    #[test]
    fn rndaddentropy_matches_the_kernel_encoding() {
        // _IOW('R', 0x03, int[2]): dir=1 (write) << 30 | size=8 << 16
        //                          | 'R' (0x52) << 8 | 0x03
        let expected: libc::Ioctl = (1 << 30) | (8 << 16) | (0x52 << 8) | 0x03;
        assert_eq!(RNDADDENTROPY, expected);
    }
}
