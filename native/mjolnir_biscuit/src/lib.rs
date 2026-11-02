// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 World Tree Network Foundation and the Mjolnir contributors

//! Host Biscuit face (`mjolnir-axsb.1.7`).
//!
//! Mint/verify and §5 fingerprints come from `identikey-capability`.
//! This crate keeps the JSON CLI, `COMMIT_DOMAIN`, and BEAM-facing
//! names. No HTTP. No vsock. No second biscuit-auth mint path.

pub mod direct_challenge;

pub use identikey_capability::{
    append_holder_check, blake3_hash, holder_fingerprint, keypair_from_private_hex, mint_right,
    new_keypair, parse, public_from_hex, Biscuit, KeyPair, PublicKey, EMPTY_BLAKE3,
};

use identikey_capability::{authorize, secret_commit as proto_commit, CapabilityError};

/// Mjolnir secret-commitment domain. Passed into the protocol helper.
pub const COMMIT_DOMAIN: &[u8] = b"mjolnir/secret-commit/v1";

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("biscuit: {0}")]
    Biscuit(String),
    #[error("key: {0}")]
    Key(String),
    #[error("ed25519 public key must be 32 bytes")]
    PublicLen,
}

impl From<CapabilityError> for Error {
    fn from(e: CapabilityError) -> Self {
        match e {
            CapabilityError::PublicLen => Error::PublicLen,
            CapabilityError::Key(s) => Error::Key(s),
            other => Error::Biscuit(other.to_string()),
        }
    }
}

pub fn secret_commit(salt: &[u8], secret: &[u8]) -> [u8; 32] {
    proto_commit(COMMIT_DOMAIN, salt, secret)
}

/// Record one nextKey hop, preserving the canonical holder binding.
///
/// Compare parsed checks, including every query/alternative and scope. Symbols
/// are only candidates: a fingerprint is accepted only when the entire check
/// equals the canonical check containing that string literal. This
/// avoids parsing display text and needs only the re-exported Biscuit type.
pub fn append_hop(tok: &Biscuit) -> Result<Vec<u8>, Error> {
    let (_, _, checks, _) = tok
        .authorizer()
        .map_err(|e| Error::Biscuit(e.to_string()))?
        .dump();
    for index in 0..tok.block_count() {
        for fp in tok
            .block_symbols(index)
            .map_err(|e| Error::Biscuit(e.to_string()))?
        {
            // JSON quoting keeps the symbol a single Datalog string literal.
            let source = format!(
                "check if holder($fp), $fp == {}",
                serde_json::to_string(&fp).map_err(|e| Error::Biscuit(e.to_string()))?
            );
            let Ok(builder) = Biscuit::builder().check(source.as_str()) else {
                continue;
            };
            let (_, _, mut canonical_checks) = builder.dump();
            let mut canonical = canonical_checks.remove(0);
            // Deserialized checks have no builder parameter bookkeeping.
            for query in &mut canonical.queries {
                query.parameters = None;
                query.scope_parameters = None;
            }
            if checks.contains(&canonical) {
                // The protocol helper performs exactly one Biscuit::append
                // with this check alone, then serializes before returning.
                return append_holder_check(tok, &fp).map_err(Error::from);
            }
        }
    }
    Err(Error::Biscuit("canonical holder check missing".into()))
}

/// Authorize with an optional injected `holder` fact. `inject_holder` is
/// the BEAM flag; the protocol crate takes `Option<&str>`.
pub fn authorize_holder(
    bytes: &[u8],
    root_public: PublicKey,
    fp: &str,
    resource: &str,
    operation: &str,
    inject_holder: bool,
) -> Result<(), Error> {
    let holder = inject_holder.then_some(fp);
    authorize(bytes, root_public, holder, resource, operation).map_err(Error::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_blake3_vector() {
        assert_eq!(blake3_hash(b""), EMPTY_BLAKE3);
    }

    #[test]
    fn holder_fp_is_not_raw_blake3() {
        let pub_bytes = [0x11u8; 32];
        let fp = holder_fingerprint(&pub_bytes).unwrap();
        assert_ne!(fp, blake3_hash(&pub_bytes));
        assert_eq!(
            hex::encode(fp),
            "082474a2550d241689396cae8be5b2aa8a63e82509b6a5ca4aaf57592e2a74a1"
        );
    }

    #[test]
    fn commit_is_domain_separated() {
        let c = secret_commit(b"salt", b"secret");
        assert_ne!(c, blake3_hash(b"secret"));
        assert_ne!(c, proto_commit(b"other/v1", b"salt", b"secret"));
        assert_eq!(c.len(), 32);
    }

    #[test]
    fn mint_round_trip() {
        let root = new_keypair();
        let bytes = mint_right(&root, "github-pat-ci", "redeem").unwrap();
        parse(&bytes, root.public()).unwrap();
    }

    #[test]
    fn hop_preserves_canonical_holder_check() {
        let root = new_keypair();
        let minted = mint_right(&root, "secret", "redeem").unwrap();
        let held = append_holder_check(&parse(&minted, root.public()).unwrap(), "FP").unwrap();
        let tok = parse(&held, root.public()).unwrap();
        let hopped = append_hop(&tok).unwrap();
        let next = parse(&hopped, root.public()).unwrap();
        assert_eq!(next.block_count(), tok.block_count() + 1);
        assert_eq!(
            next.print_block_source(1).unwrap(),
            next.print_block_source(2).unwrap()
        );
        authorize_holder(&hopped, root.public(), "FP", "secret", "redeem", true).unwrap();
    }

    #[test]
    fn hop_requires_an_entire_canonical_check() {
        let root = new_keypair();
        for source in [
            r#"check if holder($fp), $fp == "FP" or true"#,
            r#"check if holder($fp), $fp.starts_with("FP")"#,
            r#"check if holder($fp), $fp == "FP", true"#,
            r#"check all holder($fp), $fp == "FP""#,
            r#"check if other_holder($fp), $fp == "FP""#,
            r#"check if true"#,
        ] {
            let tok = Biscuit::builder()
                .check(source)
                .unwrap()
                .build(&root)
                .unwrap();
            assert!(append_hop(&tok).is_err(), "accepted {source}");
        }

        // Holder-shaped text inside a fact is not a holder check.
        let tok = Biscuit::builder()
            .fact(r#"note("check if holder($fp), $fp == \"FP\";")"#)
            .unwrap()
            .build(&root)
            .unwrap();
        assert!(append_hop(&tok).is_err());
    }

    #[test]
    fn holder_check_and_tamper() {
        let root = new_keypair();
        let fp = "FP";
        let minted = mint_right(&root, "github-pat-ci", "redeem").unwrap();
        let tok = parse(&minted, root.public()).unwrap();
        let held = append_holder_check(&tok, fp).unwrap();

        authorize_holder(&held, root.public(), fp, "github-pat-ci", "redeem", true).unwrap();
        assert!(
            authorize_holder(&held, root.public(), fp, "github-pat-ci", "redeem", false).is_err()
        );

        let mut bad = minted.clone();
        let i = bad.len() / 2;
        bad[i] ^= 0xff;
        assert!(parse(&bad, root.public()).is_err());
    }
}
