//! Host Biscuit mint/verify plus protocol Blake3 (`mjolnir-axsb.1.3`).
//!
//! No HTTP. No vsock. The BEAM talks to the `mjolnir-biscuit` binary.

use biscuit_auth::{
    builder::Algorithm,
    macros::{authorizer, biscuit, block},
    Biscuit, KeyPair, PrivateKey, PublicKey,
};

pub const COMMIT_DOMAIN: &[u8] = b"mjolnir/secret-commit/v1";
pub const EMPTY_BLAKE3: [u8; 32] = [
    0xAF, 0x13, 0x49, 0xB9, 0xF5, 0xF9, 0xA1, 0xA6, 0xA0, 0x40, 0x4D, 0xEA, 0x36, 0xDC, 0xC9,
    0x49, 0x9B, 0xCB, 0x25, 0xC9, 0xAD, 0xC1, 0x12, 0xB7, 0xCC, 0x9A, 0x93, 0xCA, 0xE4, 0x1F,
    0x32, 0x62,
];

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("biscuit: {0}")]
    Biscuit(String),
    #[error("key: {0}")]
    Key(String),
    #[error("ed25519 public key must be 32 bytes")]
    PublicLen,
}

pub fn blake3_hash(data: &[u8]) -> [u8; 32] {
    *blake3::hash(data).as_bytes()
}

/// identikey-auth v1 §5: Blake3(dcbor({"alg":"ed25519","key": pub})).
pub fn holder_fingerprint(ed25519_pub: &[u8]) -> Result<[u8; 32], Error> {
    if ed25519_pub.len() != 32 {
        return Err(Error::PublicLen);
    }
    Ok(blake3_hash(&dcbor_public_key("ed25519", ed25519_pub)))
}

pub fn secret_commit(salt: &[u8], secret: &[u8]) -> [u8; 32] {
    let mut buf = Vec::with_capacity(COMMIT_DOMAIN.len() + salt.len() + secret.len());
    buf.extend_from_slice(COMMIT_DOMAIN);
    buf.extend_from_slice(salt);
    buf.extend_from_slice(secret);
    blake3_hash(&buf)
}

fn dcbor_public_key(alg: &str, key: &[u8]) -> Vec<u8> {
    // Canonical map, keys sorted by encoded-byte order: "alg" then "key".
    let mut out = Vec::new();
    encode_head(5, 2, &mut out);
    encode_text("alg", &mut out);
    encode_text(alg, &mut out);
    encode_text("key", &mut out);
    encode_bytes(key, &mut out);
    out
}

fn encode_head(major: u8, n: u64, out: &mut Vec<u8>) {
    if n < 24 {
        out.push((major << 5) | (n as u8));
    } else if n < 256 {
        out.push((major << 5) | 24);
        out.push(n as u8);
    } else if n < 65536 {
        out.push((major << 5) | 25);
        out.extend_from_slice(&(n as u16).to_be_bytes());
    } else if n < (1 << 32) {
        out.push((major << 5) | 26);
        out.extend_from_slice(&(n as u32).to_be_bytes());
    } else {
        out.push((major << 5) | 27);
        out.extend_from_slice(&n.to_be_bytes());
    }
}

fn encode_text(s: &str, out: &mut Vec<u8>) {
    encode_head(3, s.len() as u64, out);
    out.extend_from_slice(s.as_bytes());
}

fn encode_bytes(b: &[u8], out: &mut Vec<u8>) {
    encode_head(2, b.len() as u64, out);
    out.extend_from_slice(b);
}

pub fn new_keypair() -> KeyPair {
    KeyPair::new()
}

pub fn keypair_from_private_hex(hex_str: &str) -> Result<KeyPair, Error> {
    let bytes = hex::decode(hex_str.trim()).map_err(|e| Error::Key(e.to_string()))?;
    let private = PrivateKey::from_bytes(&bytes, Algorithm::Ed25519)
        .map_err(|e| Error::Key(e.to_string()))?;
    Ok(KeyPair::from(&private))
}

pub fn public_from_hex(hex_str: &str) -> Result<PublicKey, Error> {
    let bytes = hex::decode(hex_str.trim()).map_err(|e| Error::Key(e.to_string()))?;
    PublicKey::from_bytes(&bytes, Algorithm::Ed25519).map_err(|e| Error::Key(e.to_string()))
}

pub fn mint_right(root: &KeyPair, resource: &str, operation: &str) -> Result<Vec<u8>, Error> {
    let tok = biscuit!(
        r#"right({resource}, {operation});"#,
        resource = resource,
        operation = operation,
    )
    .build(root)
    .map_err(|e| Error::Biscuit(e.to_string()))?;
    tok.to_vec().map_err(|e| Error::Biscuit(e.to_string()))
}

pub fn parse(bytes: &[u8], root_public: PublicKey) -> Result<Biscuit, Error> {
    Biscuit::from(bytes, root_public).map_err(|e| Error::Biscuit(e.to_string()))
}

pub fn append_holder_check(tok: &Biscuit, fp: &str) -> Result<Vec<u8>, Error> {
    let next = tok
        .append(block!(
            r#"check if holder($fp), $fp == {fp};"#,
            fp = fp,
        ))
        .map_err(|e| Error::Biscuit(e.to_string()))?;
    next.to_vec().map_err(|e| Error::Biscuit(e.to_string()))
}

pub fn authorize_holder(
    bytes: &[u8],
    root_public: PublicKey,
    fp: &str,
    resource: &str,
    operation: &str,
    inject_holder: bool,
) -> Result<(), Error> {
    let tok = parse(bytes, root_public)?;
    let mut built = if inject_holder {
        authorizer!(
            r#"
            holder({fp});
            allow if right({resource}, {operation});
            "#,
            fp = fp,
            resource = resource,
            operation = operation,
        )
        .build(&tok)
        .map_err(|e| Error::Biscuit(e.to_string()))?
    } else {
        authorizer!(
            r#"
            allow if right({resource}, {operation});
            "#,
            resource = resource,
            operation = operation,
        )
        .build(&tok)
        .map_err(|e| Error::Biscuit(e.to_string()))?
    };
    built
        .authorize()
        .map(|_| ())
        .map_err(|e| Error::Biscuit(e.to_string()))
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
        assert_eq!(fp.len(), 32);
        // Fixture for 32×0x11 under §5 dCBOR {alg:ed25519,key}.
        assert_eq!(
            hex::encode(fp),
            "082474a2550d241689396cae8be5b2aa8a63e82509b6a5ca4aaf57592e2a74a1"
        );
    }

    #[test]
    fn commit_is_domain_separated() {
        let salt = b"salt";
        let secret = b"secret";
        let c = secret_commit(salt, secret);
        assert_ne!(c, blake3_hash(secret));
        assert_eq!(c.len(), 32);
    }

    #[test]
    fn mint_round_trip() {
        let root = KeyPair::new();
        let bytes = mint_right(&root, "github-pat-ci", "redeem").unwrap();
        parse(&bytes, root.public()).unwrap();
    }

    #[test]
    fn holder_check_and_tamper() {
        let root = KeyPair::new();
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
