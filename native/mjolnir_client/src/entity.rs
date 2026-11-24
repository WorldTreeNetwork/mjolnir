//! A unikernel entity's key file and name.
//!
//! The key is a 32-byte Ed25519 seed in a file of exactly 32 bytes, made by
//! its owner with any tool (`head -c 32 /dev/urandom > key`). The name is
//! identikey's fingerprint of the public key: Blake3 of the dCBOR of
//! `{"alg": "ed25519", "key": <32 bytes>}`, written as base58 with the
//! Bitcoin alphabet, no checksum, each leading zero byte as `1`. Same as
//! homoiconic `unikernel/entity.zig` and `native/reflect_quic/entity-tool.zig`.

use anyhow::{bail, Context, Result};

/// dCBOR of the map up to the key's bytes.
const PREFIX: [u8; 19] = [
    0xa2, 0x63, b'a', b'l', b'g', 0x67, b'e', b'd', b'2', b'5', b'5', b'1', b'9', 0x63, b'k', b'e',
    b'y', 0x58, 0x20,
];

const ALPHABET: &[u8; 58] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// Read a key file: exactly 32 bytes, not all zero. The bytes are never printed.
pub fn read_key_file(path: &str) -> Result<[u8; 32]> {
    let bytes = std::fs::read(path).with_context(|| format!("cannot read key file {path}"))?;
    if bytes.len() != 32 {
        bail!(
            "key file {path} holds {} bytes; an entity key is exactly 32",
            bytes.len()
        );
    }
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&bytes);
    if seed.iter().all(|b| *b == 0) {
        bail!("key file {path} is all zero");
    }
    Ok(seed)
}

/// Base58 of raw bytes. A leading zero byte is written as `1`.
pub fn base58(bytes: &[u8]) -> String {
    let zeros = bytes.iter().take_while(|b| **b == 0).count();
    let mut num = bytes[zeros..].to_vec();
    let mut digits = Vec::new();
    let mut first = 0;
    while first < num.len() {
        let mut rem: u32 = 0;
        for b in num[first..].iter_mut() {
            let v = rem * 256 + u32::from(*b);
            *b = (v / 58) as u8;
            rem = v % 58;
        }
        digits.push(ALPHABET[rem as usize]);
        while first < num.len() && num[first] == 0 {
            first += 1;
        }
    }
    let mut out = "1".repeat(zeros);
    out.extend(digits.iter().rev().map(|d| *d as char));
    out
}

/// The entity's name for a seed.
pub fn name_of(seed: &[u8; 32]) -> String {
    let public = ed25519_dalek::SigningKey::from_bytes(seed)
        .verifying_key()
        .to_bytes();
    let mut hasher = blake3::Hasher::new();
    hasher.update(&PREFIX);
    hasher.update(&public);
    base58(hasher.finalize().as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identikey_fixture_seed_has_identikeys_name() {
        // homoiconic openspec/changes/add-entity-keys/design.md, section 1.
        assert_eq!(
            name_of(&[0x11; 32]),
            "6mUFfKo4KPLqjeAVqthhCZB82jgWjbo3RPJAAWdTynq1"
        );
    }

    #[test]
    fn base58_writes_leading_zero_bytes_as_ones() {
        assert_eq!(base58(&[0, 0, 1]), "112");
        assert_eq!(base58(&[0; 32]), "1".repeat(32));
    }
}
