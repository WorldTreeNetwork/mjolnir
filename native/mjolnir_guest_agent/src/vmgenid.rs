//! Read the VM Generation ID the guest can actually see.
//!
//! Cloud Hypervisor's v54 device changes a 16-byte counter on restore. The
//! ch-6.12.8 `vmgenid` driver copies that counter into `add_vmfork_randomness`
//! and does not publish it. `scripts/build-kernel.sh` adds
//! `/sys/firmware/vmgenid/generation_id` (32 lowercase hex digits, the live
//! counter). This module reads that file and nothing else. `/dev/urandom` is
//! not a generation id.

use std::fs;
use std::io;

pub const SYSFS_PATH: &str = "/sys/firmware/vmgenid/generation_id";

#[derive(Debug)]
pub struct Observation {
    pub ok: bool,
    pub generation_id: Option<String>,
    pub error: Option<String>,
}

/// Accept only 16 bytes rendered as 32 hex digits. Anything else, including a
/// urandom sample or a UUID with dashes, is not an observation.
pub fn parse_generation_id(text: &str) -> Result<String, String> {
    let id = text.trim();
    if id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit()) {
        Ok(id.to_ascii_lowercase())
    } else {
        Err(format!("generation id is not 32 hex digits ({})", id.len()))
    }
}

pub fn read_generation_id() -> Observation {
    match fs::read_to_string(SYSFS_PATH) {
        Ok(text) => match parse_generation_id(&text) {
            Ok(id) => Observation {
                ok: true,
                generation_id: Some(id),
                error: None,
            },
            Err(error) => Observation {
                ok: false,
                generation_id: None,
                error: Some(error),
            },
        },
        Err(error) if error.kind() == io::ErrorKind::NotFound => Observation {
            ok: false,
            generation_id: None,
            error: Some("vmgenid sysfs missing".into()),
        },
        Err(error) => Observation {
            ok: false,
            generation_id: None,
            error: Some(error.to_string()),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::parse_generation_id;

    #[test]
    fn accepts_sixteen_raw_bytes_of_hex() {
        let id = "00112233445566778899aabbccddeeff";
        assert_eq!(parse_generation_id(id).unwrap(), id);
        assert_eq!(
            parse_generation_id("AABBCCDDEEFF00112233445566778899\n").unwrap(),
            "aabbccddeeff00112233445566778899"
        );
    }

    #[test]
    fn rejects_urandom_text_and_dashed_uuids() {
        assert!(parse_generation_id("not-a-device-id").is_err());
        assert!(parse_generation_id("00112233-4455-6677-8899-aabbccddeeff").is_err());
        assert!(parse_generation_id("").is_err());
    }
}
