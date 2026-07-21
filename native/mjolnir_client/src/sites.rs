//! `mjolnir sites publish` — publish a local directory as a public-mode
//! IdentiKey site, and `mjolnir sites keygen` — mint the keypair that signs it.
//!
//! This is a byte-compatible port of the Elixir publisher
//! (`lib/mjolnir/sites/publisher.ex` + the `mix mjolnir.sites.publish` task).
//! The Elixir side is the spec; everything here exists to produce envelopes
//! that Elixir can parse and verify unchanged.
//!
//! ## Why byte-exactness matters
//!
//! The server does not verify the signature against the bytes it received. It
//! re-parses the envelope into a struct and re-serializes it with the field
//! cleared (`SecretStore.canonical_bytes_without_sig/2`). So a signature only
//! verifies if `elixir_serialize(parse(our_json))` equals the JSON we signed,
//! byte for byte. Three details carry that:
//!
//! * **Key order** — Jason serializes an Elixir map in term order, and maps of
//!   =<32 keys are sorted. Every record here declares its fields in the same
//!   sorted order, which is the order serde emits them in.
//! * **Cleared signature** — the field is present and `null`, not omitted.
//! * **Timestamps** — `DateTime.truncate(:second) |> DateTime.to_iso8601()`,
//!   i.e. `2026-07-21T12:34:56Z`. No sub-second component, `Z` suffix.
//!
//! ## Crypto compatibility
//!
//! `Mjolnir.Sites.Crypto.blake3_hash/1` is **currently a SHA-256 stub** (see its
//! moduledoc — the Blake3 NIF was backed out). Every `bao_hash`, snapshot hash
//! and IdentiKey fingerprint is therefore SHA-256, base58-encoded. When the
//! Elixir side swaps in real Blake3, [`content_hash`] must swap with it.
//!
//! The base58 encoder is a plain big-integer conversion with **no leading-zero
//! handling** — it mirrors `Crypto.base58_encode/1` exactly, which means a
//! digest with leading zero bytes encodes shorter. That is a deviation from
//! Bitcoin base58check, so the `bs58` crate cannot be substituted here.

use anyhow::{bail, Context, Result};
use serde::Serialize;
use std::path::{Path, PathBuf};

use crate::api::api_client;
use crate::config::Profile;

/// The server reads request bodies with `length: 64 * 1024 * 1024`; anything
/// larger comes back as `{:more, ...}` and is rejected as `body_too_large`.
const MAX_BODY: usize = 64 * 1024 * 1024;

/// Framing overhead of a chunk upload: two big-endian u64 length prefixes.
const FRAME_OVERHEAD: usize = 16;

// ---------------------------------------------------------------------------
// Wire records
// ---------------------------------------------------------------------------

/// Forward-compatible signature envelope (`Mjolnir.Sites.MultiSig`).
///
/// On the wire a populated signature is `{"ed25519": "<base64>"}`. The eventual
/// ML-DSA leg is an additional key; absent legs are omitted, so the struct only
/// carries the one leg we can produce.
#[derive(Serialize, Debug, Clone, PartialEq)]
struct MultiSig {
    ed25519: String,
}

/// One file in a snapshot. Field order is the sorted order Jason emits.
#[derive(Serialize, Debug, Clone, PartialEq)]
struct Entry {
    bao_hash: String,
    ciphertext_size: usize,
    content_encoding: Option<String>,
    content_type: String,
    /// base64 of the 24-byte XChaCha20 nonce.
    nonce: String,
    path: String,
    plaintext_size: usize,
    /// Public mode never wraps keys; always `null`.
    wrapped_key: Option<String>,
}

/// Snapshot manifest (`Mjolnir.Sites.Manifest`). Field order is sorted.
#[derive(Serialize, Debug, Clone, PartialEq)]
struct Manifest {
    created_at: String,
    entries: Vec<Entry>,
    identikey_fp: String,
    mode: String,
    signatures: Option<MultiSig>,
    site_name: String,
    /// base64 of the 32-byte per-snapshot seed.
    sym_seed: String,
    version: u32,
}

/// HEAD pointer record (`Mjolnir.Sites.HeadRecord`). Field order is sorted.
#[derive(Serialize, Debug, Clone, PartialEq)]
struct HeadRecord {
    created_at: String,
    identikey_fp: String,
    sequence: u64,
    signature: Option<MultiSig>,
    site_name: String,
    snapshot_hash: String,
    version: u32,
}

/// Custom-domain alias record (`Mjolnir.Sites.AliasRecord`). Field order is the
/// sorted order Jason emits, same rule as [`Manifest`] and [`HeadRecord`].
///
/// A tombstone is not a distinct type: removing an alias means signing a fresh
/// record with a strictly higher sequence and sending it via DELETE.
#[derive(Serialize, Debug, Clone, PartialEq)]
struct AliasRecord {
    created_at: String,
    fqdn: String,
    identikey_fp: String,
    sequence: u64,
    signature: Option<MultiSig>,
    site_name: String,
    version: u32,
}

impl AliasRecord {
    /// The bytes an IdentiKey signs: the full envelope with `signature` nulled.
    fn canonical_signing_bytes(&self) -> Result<Vec<u8>> {
        let mut unsigned = self.clone();
        unsigned.signature = None;
        Ok(serde_json::to_vec(&unsigned)?)
    }
}

/// An ED25519 keypair in the shape `IdentiKey.keypair_from_json/1` expects:
/// both halves base64-encoded, the secret being the raw 32-byte seed that
/// `:crypto.generate_key(:eddsa, :ed25519)` returns.
#[derive(Serialize, Debug)]
struct KeypairJson {
    ed25519_public: String,
    ed25519_secret: String,
}

/// A loaded keypair: the 32-byte seed plus its derived public key.
#[derive(Clone)]
pub struct Keypair {
    secret: [u8; 32],
    public: [u8; 32],
}

impl Manifest {
    /// The bytes an IdentiKey signs: the full envelope with `signatures` nulled.
    fn canonical_signing_bytes(&self) -> Result<Vec<u8>> {
        let mut unsigned = self.clone();
        unsigned.signatures = None;
        Ok(serde_json::to_vec(&unsigned)?)
    }
}

impl HeadRecord {
    /// The bytes an IdentiKey signs: the full envelope with `signature` nulled.
    fn canonical_signing_bytes(&self) -> Result<Vec<u8>> {
        let mut unsigned = self.clone();
        unsigned.signature = None;
        Ok(serde_json::to_vec(&unsigned)?)
    }
}

// ---------------------------------------------------------------------------
// Crypto primitives (ports of Mjolnir.Sites.Crypto)
// ---------------------------------------------------------------------------

mod crypto {
    use hmac::{Hmac, Mac};
    use sha2::{Digest, Sha256};

    type HmacSha256 = Hmac<Sha256>;

    const B58_ALPHABET: &[u8; 58] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

    /// Base58 (Bitcoin alphabet) of raw bytes, as a single big-endian integer.
    ///
    /// Mirrors `Crypto.base58_encode/1`, which does `:binary.decode_unsigned/1`
    /// then repeated division. Leading zero bytes are **not** preserved — they
    /// vanish into the integer — so this is deliberately not `bs58`.
    pub fn base58_encode(bytes: &[u8]) -> String {
        if bytes.is_empty() {
            return String::new();
        }
        // Big-endian byte vector treated as a base-256 number, repeatedly
        // divided by 58. `digits` collects remainders least-significant first.
        let mut num = bytes.to_vec();
        let mut digits: Vec<u8> = Vec::new();
        // Skip leading zero bytes: they contribute nothing to the integer.
        let mut start = 0;
        while start < num.len() && num[start] == 0 {
            start += 1;
        }
        while start < num.len() {
            let mut remainder: u32 = 0;
            for byte in num.iter_mut().skip(start) {
                let acc = (remainder << 8) | u32::from(*byte);
                *byte = (acc / 58) as u8;
                remainder = acc % 58;
            }
            digits.push(B58_ALPHABET[remainder as usize]);
            while start < num.len() && num[start] == 0 {
                start += 1;
            }
        }
        digits.reverse();
        String::from_utf8(digits).expect("base58 alphabet is ASCII")
    }

    /// Content hash used for `bao_hash`, snapshot hashes and fingerprints.
    ///
    /// Named for its role, not its algorithm: the Elixir `blake3_hash/1` it
    /// mirrors is a SHA-256 stub today. Both sides must flip together.
    pub fn content_hash(bytes: &[u8]) -> [u8; 32] {
        Sha256::digest(bytes).into()
    }

    /// `content_hash` in base58 — the form that appears on the wire.
    pub fn content_hash_base58(bytes: &[u8]) -> String {
        base58_encode(&content_hash(bytes))
    }

    /// HKDF-SHA256 (RFC 5869) with an all-zero salt, matching
    /// `Crypto.hkdf_sha256/3`.
    pub fn hkdf_sha256(ikm: &[u8], info: &[u8], length: usize) -> Vec<u8> {
        // Extract: PRK = HMAC(salt = 32 zero bytes, ikm).
        let mut extract = HmacSha256::new_from_slice(&[0u8; 32]).expect("hmac accepts any key len");
        extract.update(ikm);
        let prk = extract.finalize().into_bytes();

        // Expand: T(i) = HMAC(PRK, T(i-1) || info || i)
        let mut out: Vec<u8> = Vec::with_capacity(length + 32);
        let mut previous: Vec<u8> = Vec::new();
        let mut counter: u8 = 1;
        while out.len() < length {
            let mut mac = HmacSha256::new_from_slice(&prk).expect("hmac accepts any key len");
            mac.update(&previous);
            mac.update(info);
            mac.update(&[counter]);
            previous = mac.finalize().into_bytes().to_vec();
            out.extend_from_slice(&previous);
            counter += 1;
        }
        out.truncate(length);
        out
    }

    const CHACHA_CONSTANTS: [u32; 4] = [0x6170_7865, 0x3320_646E, 0x7962_2D32, 0x6B20_6574];

    /// One ChaCha quarter-round on four state words.
    fn quarter_round(state: &mut [u32; 16], a: usize, b: usize, c: usize, d: usize) {
        state[a] = state[a].wrapping_add(state[b]);
        state[d] = (state[d] ^ state[a]).rotate_left(16);
        state[c] = state[c].wrapping_add(state[d]);
        state[b] = (state[b] ^ state[c]).rotate_left(12);
        state[a] = state[a].wrapping_add(state[b]);
        state[d] = (state[d] ^ state[a]).rotate_left(8);
        state[c] = state[c].wrapping_add(state[d]);
        state[b] = (state[b] ^ state[c]).rotate_left(7);
    }

    /// 20 rounds (10 column/diagonal double-rounds) over the state, in place.
    fn twenty_rounds(state: &mut [u32; 16]) {
        for _ in 0..10 {
            quarter_round(state, 0, 4, 8, 12);
            quarter_round(state, 1, 5, 9, 13);
            quarter_round(state, 2, 6, 10, 14);
            quarter_round(state, 3, 7, 11, 15);
            quarter_round(state, 0, 5, 10, 15);
            quarter_round(state, 1, 6, 11, 12);
            quarter_round(state, 2, 7, 8, 13);
            quarter_round(state, 3, 4, 9, 14);
        }
    }

    fn load_le(bytes: &[u8]) -> u32 {
        u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
    }

    /// HChaCha20 per draft-irtf-cfrg-xchacha §2.2: 20 rounds over the state,
    /// returning words 0..3 and 12..15 *without* adding the initial state back.
    fn hchacha20(key: &[u8; 32], nonce16: &[u8; 16]) -> [u8; 32] {
        let mut state = [0u32; 16];
        state[..4].copy_from_slice(&CHACHA_CONSTANTS);
        for i in 0..8 {
            state[4 + i] = load_le(&key[i * 4..]);
        }
        for i in 0..4 {
            state[12 + i] = load_le(&nonce16[i * 4..]);
        }
        twenty_rounds(&mut state);

        let mut out = [0u8; 32];
        for i in 0..4 {
            out[i * 4..i * 4 + 4].copy_from_slice(&state[i].to_le_bytes());
            out[16 + i * 4..16 + i * 4 + 4].copy_from_slice(&state[12 + i].to_le_bytes());
        }
        out
    }

    /// XChaCha20 as a raw stream cipher — no auth tag, ciphertext length equals
    /// plaintext length, and decryption is the same operation.
    ///
    /// `nonce[0..16]` derives a subkey via HChaCha20; the 12-byte ChaCha20
    /// nonce is four zero bytes followed by `nonce[16..24]`, with the block
    /// counter starting at 0. This matches `Crypto.xchacha20_encrypt/3`, which
    /// feeds OTP a 16-byte IV of `<<counter::32-little, 0::32, tail::binary>>`.
    pub fn xchacha20_xor(key: &[u8; 32], nonce: &[u8; 24], data: &[u8]) -> Vec<u8> {
        let mut nonce16 = [0u8; 16];
        nonce16.copy_from_slice(&nonce[..16]);
        let subkey = hchacha20(key, &nonce16);

        let mut chacha_nonce = [0u8; 12];
        chacha_nonce[4..].copy_from_slice(&nonce[16..]);

        let mut base = [0u32; 16];
        base[..4].copy_from_slice(&CHACHA_CONSTANTS);
        for i in 0..8 {
            base[4 + i] = load_le(&subkey[i * 4..]);
        }
        for i in 0..3 {
            base[13 + i] = load_le(&chacha_nonce[i * 4..]);
        }

        let mut out = Vec::with_capacity(data.len());
        for (block_index, block) in data.chunks(64).enumerate() {
            let mut state = base;
            state[12] = block_index as u32;
            let mut working = state;
            twenty_rounds(&mut working);
            // ChaCha20 proper adds the initial state back before output.
            let mut keystream = [0u8; 64];
            for i in 0..16 {
                let word = working[i].wrapping_add(state[i]);
                keystream[i * 4..i * 4 + 4].copy_from_slice(&word.to_le_bytes());
            }
            out.extend(block.iter().zip(keystream.iter()).map(|(b, k)| b ^ k));
        }
        out
    }
}

// ---------------------------------------------------------------------------
// Keypair handling
// ---------------------------------------------------------------------------

impl Keypair {
    /// Derive the public half from a 32-byte ED25519 seed.
    fn from_seed(secret: [u8; 32]) -> Self {
        let signing = ed25519_dalek::SigningKey::from_bytes(&secret);
        let public = signing.verifying_key().to_bytes();
        Self { secret, public }
    }

    fn generate() -> Self {
        use rand::RngCore;
        let mut seed = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut seed);
        Self::from_seed(seed)
    }

    /// Load a keypair from the JSON shape `IdentiKey.keypair_to_json/1` writes.
    ///
    /// The stored public key is re-derived from the seed rather than trusted,
    /// so a corrupted or mismatched file fails here instead of producing
    /// signatures the server silently rejects.
    fn from_json(json: &str) -> Result<Self> {
        #[derive(serde::Deserialize)]
        struct Raw {
            ed25519_public: String,
            ed25519_secret: String,
        }
        let raw: Raw = serde_json::from_str(json).context("keypair file is not valid JSON")?;
        let secret = decode_b64_fixed::<32>(&raw.ed25519_secret, "ed25519_secret")?;
        let stored_public = decode_b64_fixed::<32>(&raw.ed25519_public, "ed25519_public")?;

        let keypair = Self::from_seed(secret);
        if keypair.public != stored_public {
            bail!("keypair file is inconsistent: ed25519_public does not match ed25519_secret");
        }
        Ok(keypair)
    }

    fn to_json(&self) -> Result<String> {
        Ok(serde_json::to_string(&KeypairJson {
            ed25519_public: b64(&self.public),
            ed25519_secret: b64(&self.secret),
        })?)
    }

    /// base58 of the public key's content hash — the site's root identifier.
    fn fingerprint(&self) -> String {
        crypto::content_hash_base58(&self.public)
    }

    fn sign(&self, message: &[u8]) -> [u8; 64] {
        use ed25519_dalek::Signer;
        ed25519_dalek::SigningKey::from_bytes(&self.secret)
            .sign(message)
            .to_bytes()
    }

    /// Wrap a signature over `message` in the wire-format MultiSig envelope.
    fn multi_sig(&self, message: &[u8]) -> MultiSig {
        MultiSig {
            ed25519: b64(&self.sign(message)),
        }
    }
}

fn b64(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn decode_b64_fixed<const N: usize>(value: &str, field: &str) -> Result<[u8; N]> {
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(value)
        .with_context(|| format!("{} is not valid base64", field))?;
    bytes
        .try_into()
        .map_err(|v: Vec<u8>| anyhow::anyhow!("{} must be {} bytes, got {}", field, N, v.len()))
}

/// Current UTC time in the format `DateTime.truncate(:second)` +
/// `DateTime.to_iso8601/1` produce. Sub-second precision would survive the
/// Elixir parse/serialize round-trip and break every signature.
fn now_iso8601() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

// ---------------------------------------------------------------------------
// Snapshot building
// ---------------------------------------------------------------------------

/// An encrypted file body plus its Bao outboard, keyed by `bao_hash`.
struct Chunk {
    ciphertext: Vec<u8>,
    /// Always empty in phase 1 — the Elixir publisher sets `outboard: <<>>`.
    outboard: Vec<u8>,
}

/// Content-type sniffing, mirroring `Publisher.mime_of/1` exactly. Anything
/// unrecognized is `application/octet-stream`.
fn mime_of(path: &str) -> &'static str {
    let ext = Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("");
    match ext {
        "html" => "text/html; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "js" => "application/javascript",
        "json" => "application/json",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "txt" => "text/plain; charset=utf-8",
        _ => "application/octet-stream",
    }
}

/// Walk `dir` recursively, returning `(absolute_path, rel_path)` for every
/// regular file, sorted by `rel_path`. `rel_path` is relative to `dir` with a
/// leading `/`.
///
/// This deliberately does **not** use the `ignore` crate's gitignore filtering,
/// unlike `deploy`: the input here is a build output directory, which is
/// usually gitignored in its entirety. Dotfiles are included, matching the
/// Elixir walk, which collects every regular file without exception.
///
/// Symlinks are followed for the regular-file test (`fs::metadata`, like
/// Elixir's `File.stat/1`) but directory recursion uses `read_dir`, so a
/// symlink to a directory is not descended into — matching `File.ls/1` +
/// `File.stat/1` behavior only for files. Symlinked directories are rare in
/// build output; see the report note.
fn collect_files(dir: &Path) -> Result<Vec<(PathBuf, String)>> {
    let base = dir
        .canonicalize()
        .with_context(|| format!("cannot access directory: {}", dir.display()))?;
    let mut files = Vec::new();
    walk(&base, &base, &mut files)?;
    files.sort_by(|a, b| a.1.cmp(&b.1));
    Ok(files)
}

fn walk(path: &Path, base: &Path, out: &mut Vec<(PathBuf, String)>) -> Result<()> {
    // Elixir's `File.ls/1` returns `{:error, _}` for unreadable dirs and the
    // publisher treats that as "no entries". Mirror that tolerance.
    let entries = match std::fs::read_dir(path) {
        Ok(e) => e,
        Err(_) => return Ok(()),
    };
    for entry in entries {
        let entry = entry.with_context(|| format!("failed to read {}", path.display()))?;
        let full = entry.path();
        let meta = match std::fs::metadata(&full) {
            Ok(m) => m,
            Err(_) => continue,
        };
        if meta.is_file() {
            let rel = full
                .strip_prefix(base)
                .context("walked outside the site root")?;
            out.push((full.clone(), format!("/{}", rel.to_string_lossy())));
        } else if meta.is_dir() {
            walk(&full, base, out)?;
        }
    }
    Ok(())
}

/// Build a signed manifest and the chunk map for `dir`.
///
/// Mirrors `Publisher.build_snapshot/4`: one random `sym_seed` per snapshot,
/// per-file keys derived as `HKDF-SHA256(sym_seed, info = rel_path, 32)`, a
/// fresh random nonce per file, and `bao_hash` over the *ciphertext*.
fn build_snapshot(
    dir: &Path,
    identikey_fp: &str,
    site_name: &str,
    keypair: Option<&Keypair>,
    sym_seed: [u8; 32],
) -> Result<(Manifest, Vec<(String, Chunk)>)> {
    use rand::RngCore;

    let files = collect_files(dir)?;
    let mut entries = Vec::with_capacity(files.len());
    let mut chunks = Vec::with_capacity(files.len());

    for (abs_path, rel_path) in files {
        let plaintext = std::fs::read(&abs_path)
            .with_context(|| format!("failed to read {}", abs_path.display()))?;

        let mut nonce = [0u8; 24];
        rand::rngs::OsRng.fill_bytes(&mut nonce);

        let sym_key: [u8; 32] = crypto::hkdf_sha256(&sym_seed, rel_path.as_bytes(), 32)
            .try_into()
            .expect("hkdf returns the requested length");
        let ciphertext = crypto::xchacha20_xor(&sym_key, &nonce, &plaintext);
        let bao_hash = crypto::content_hash_base58(&ciphertext);

        if ciphertext.len() + FRAME_OVERHEAD > MAX_BODY {
            bail!(
                "{} is {} bytes — the server rejects chunk uploads over {} MiB",
                rel_path,
                plaintext.len(),
                MAX_BODY / (1024 * 1024)
            );
        }

        entries.push(Entry {
            bao_hash: bao_hash.clone(),
            ciphertext_size: ciphertext.len(),
            content_encoding: None,
            content_type: mime_of(&rel_path).to_string(),
            nonce: b64(&nonce),
            path: rel_path,
            plaintext_size: plaintext.len(),
            wrapped_key: None,
        });
        chunks.push((
            bao_hash,
            Chunk {
                ciphertext,
                outboard: Vec::new(),
            },
        ));
    }

    let mut manifest = Manifest {
        created_at: now_iso8601(),
        entries,
        identikey_fp: identikey_fp.to_string(),
        mode: "public".to_string(),
        signatures: None,
        site_name: site_name.to_string(),
        sym_seed: b64(&sym_seed),
        version: 1,
    };

    if let Some(kp) = keypair {
        let signing_bytes = manifest.canonical_signing_bytes()?;
        manifest.signatures = Some(kp.multi_sig(&signing_bytes));
    }

    Ok((manifest, chunks))
}

/// `<8-byte BE u64 ct_len><ciphertext><8-byte BE u64 ob_len><outboard>` — the
/// framing `SitesRouter.unframe_chunk/1` pattern-matches on.
fn frame_chunk(ciphertext: &[u8], outboard: &[u8]) -> Vec<u8> {
    let mut framed = Vec::with_capacity(ciphertext.len() + outboard.len() + FRAME_OVERHEAD);
    framed.extend_from_slice(&(ciphertext.len() as u64).to_be_bytes());
    framed.extend_from_slice(ciphertext);
    framed.extend_from_slice(&(outboard.len() as u64).to_be_bytes());
    framed.extend_from_slice(outboard);
    framed
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

#[derive(serde::Deserialize)]
struct SnapshotResponse {
    snapshot_hash: String,
    #[serde(default)]
    missing_chunks: Vec<String>,
    #[serde(default)]
    ots_status: Option<String>,
}

#[derive(serde::Deserialize)]
struct HeadResponse {
    sequence: u64,
}

#[allow(clippy::too_many_arguments)]
pub async fn cmd_publish(
    profile: &Profile,
    api_flag: &Option<String>,
    token: &Option<String>,
    directory: &str,
    identikey_fp: &str,
    site: &str,
    base_url: &Option<String>,
    keypair_file: &Option<String>,
    sequence: u64,
) -> Result<()> {
    let dir = PathBuf::from(directory);
    if !dir.is_dir() {
        bail!("{} is not a directory", dir.display());
    }

    // `--base-url` mirrors the mix task; without it fall back to the profile's
    // configured API, so `mj sites publish` behaves like every other subcommand.
    let base = match base_url {
        Some(u) => u.trim_end_matches('/').to_string(),
        None => crate::config::resolve_api(api_flag, profile)
            .trim_end_matches('/')
            .to_string(),
    };

    let keypair = match keypair_file {
        Some(path) => {
            let json = std::fs::read_to_string(path)
                .with_context(|| format!("cannot read keypair file {}", path))?;
            Some(Keypair::from_json(&json).with_context(|| format!("invalid keypair {}", path))?)
        }
        None => None,
    };

    if let Some(ref kp) = keypair {
        let derived = kp.fingerprint();
        if derived != identikey_fp {
            bail!(
                "keypair fingerprint {} does not match --identikey-fp {}",
                derived,
                identikey_fp
            );
        }
    }

    eprintln!(
        "Publishing {} → {}/api/sites/{}/{} (sequence={})",
        dir.display(),
        base,
        identikey_fp,
        site,
        sequence
    );

    let mut sym_seed = [0u8; 32];
    {
        use rand::RngCore;
        rand::rngs::OsRng.fill_bytes(&mut sym_seed);
    }
    let (manifest, chunks) = build_snapshot(&dir, identikey_fp, site, keypair.as_ref(), sym_seed)?;
    if manifest.entries.is_empty() {
        bail!("{} contains no files to publish", dir.display());
    }
    let manifest_bytes = serde_json::to_vec(&manifest)?;
    if manifest_bytes.len() > MAX_BODY {
        bail!(
            "manifest is {} bytes — too many files for the server's {} MiB body limit",
            manifest_bytes.len(),
            MAX_BODY / (1024 * 1024)
        );
    }
    eprintln!(
        "  {} files, {} manifest bytes",
        manifest.entries.len(),
        manifest_bytes.len()
    );

    let client = api_client(token).await;

    // 1. Bootstrap the identity record so the server can verify the signed HEAD
    //    that follows. Idempotent; skipped entirely for unsigned publishes.
    if let Some(ref kp) = keypair {
        register_identity(&client, &base, identikey_fp, kp).await?;
    }

    // 2. Upload the manifest; the server tells us which chunks it lacks.
    let snapshot = post_snapshot(&client, &base, identikey_fp, site, &manifest_bytes).await?;

    // 3. Upload only the missing chunks.
    let missing = snapshot.missing_chunks.len();
    for (index, bao_hash) in snapshot.missing_chunks.iter().enumerate() {
        let chunk = chunks
            .iter()
            .find(|(h, _)| h == bao_hash)
            .map(|(_, c)| c)
            .ok_or_else(|| anyhow::anyhow!("server asked for unknown chunk {}", bao_hash))?;
        eprintln!("  uploading chunk {}/{} ({})", index + 1, missing, bao_hash);
        put_chunk(&client, &base, bao_hash, chunk).await?;
    }
    if missing == 0 {
        eprintln!("  all chunks already present");
    }

    // 4. Flip HEAD to the new snapshot.
    let head_sequence = post_head(
        &client,
        &base,
        identikey_fp,
        site,
        &snapshot.snapshot_hash,
        sequence,
        keypair.as_ref(),
    )
    .await?;

    eprintln!();
    eprintln!("\x1b[32m✔ Published {}\x1b[0m", site);
    eprintln!("  Snapshot hash : {}", snapshot.snapshot_hash);
    eprintln!("  Sequence      : {}", head_sequence);
    if let Some(ref ots) = snapshot.ots_status {
        eprintln!("  OTS           : {}", ots);
    }
    eprintln!(
        "  Serve URL     : {}/api/sites/{}/{}/files/",
        base, identikey_fp, site
    );
    // The snapshot hash goes to stdout so the command can be captured in a pipe.
    println!("{}", snapshot.snapshot_hash);
    Ok(())
}

/// Mint a fresh IdentiKey and write it to `path` with 0600 permissions.
///
/// The secret never reaches stdout — only the fingerprint and the file path do,
/// so the command is safe to run with CI logs attached.
pub fn cmd_keygen(out: &str, force: bool) -> Result<()> {
    let path = Path::new(out);
    if path.exists() && !force {
        bail!("{} already exists (pass --force to overwrite)", out);
    }
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("cannot create {}", parent.display()))?;
        }
    }

    let keypair = Keypair::generate();
    write_secret_file(path, keypair.to_json()?.as_bytes())
        .with_context(|| format!("cannot write keypair to {}", out))?;

    eprintln!("\x1b[32m✔ Wrote keypair to {}\x1b[0m (mode 0600)", out);
    eprintln!("  Fingerprint : {}", keypair.fingerprint());
    eprintln!();
    eprintln!("Keep this file secret — it is the only proof of ownership for this site.");
    // The fingerprint goes to stdout so it can be captured into CI config.
    println!("{}", keypair.fingerprint());
    Ok(())
}

/// Create-or-truncate `path` with mode 0600 *before* any bytes are written, so
/// the secret is never briefly world-readable.
#[cfg(unix)]
fn write_secret_file(path: &Path, contents: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;

    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(contents)
}

#[cfg(not(unix))]
fn write_secret_file(path: &Path, contents: &[u8]) -> std::io::Result<()> {
    std::fs::write(path, contents)
}

// ---------------------------------------------------------------------------
// HTTP steps
// ---------------------------------------------------------------------------

async fn register_identity(
    client: &reqwest::Client,
    base: &str,
    fp: &str,
    keypair: &Keypair,
) -> Result<()> {
    let body = serde_json::json!({ "pubkey": b64(&keypair.public) });
    let resp = client
        .put(format!("{}/api/sites/{}/identity", base, fp))
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .json(&body)
        .send()
        .await
        .context("identity registration request failed")?;

    let status = resp.status();
    if status == reqwest::StatusCode::OK || status == reqwest::StatusCode::CREATED {
        return Ok(());
    }
    let text = resp.text().await.unwrap_or_default();
    bail!("identity registration failed ({}): {}", status, text.trim());
}

async fn post_snapshot(
    client: &reqwest::Client,
    base: &str,
    fp: &str,
    site: &str,
    manifest_bytes: &[u8],
) -> Result<SnapshotResponse> {
    let resp = client
        .post(format!("{}/api/sites/{}/{}/snapshot", base, fp, site))
        .header(reqwest::header::CONTENT_TYPE, "application/octet-stream")
        .body(manifest_bytes.to_vec())
        .send()
        .await
        .context("snapshot upload request failed")?;

    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();
    if status != reqwest::StatusCode::CREATED {
        bail!("snapshot upload failed ({}): {}", status, text.trim());
    }
    serde_json::from_str(&text)
        .with_context(|| format!("unexpected snapshot response: {}", text.trim()))
}

async fn put_chunk(
    client: &reqwest::Client,
    base: &str,
    bao_hash: &str,
    chunk: &Chunk,
) -> Result<()> {
    let resp = client
        .put(format!("{}/api/sites/blob/{}", base, bao_hash))
        .header(reqwest::header::CONTENT_TYPE, "application/octet-stream")
        .body(frame_chunk(&chunk.ciphertext, &chunk.outboard))
        .send()
        .await
        .with_context(|| format!("chunk upload request failed for {}", bao_hash))?;

    let status = resp.status();
    if status == reqwest::StatusCode::CREATED {
        return Ok(());
    }
    let text = resp.text().await.unwrap_or_default();
    bail!(
        "chunk {} upload failed ({}): {}",
        bao_hash,
        status,
        text.trim()
    );
}

async fn post_head(
    client: &reqwest::Client,
    base: &str,
    fp: &str,
    site: &str,
    snapshot_hash: &str,
    sequence: u64,
    keypair: Option<&Keypair>,
) -> Result<u64> {
    let mut head = HeadRecord {
        created_at: now_iso8601(),
        identikey_fp: fp.to_string(),
        sequence,
        signature: None,
        site_name: site.to_string(),
        snapshot_hash: snapshot_hash.to_string(),
        version: 1,
    };
    if let Some(kp) = keypair {
        let signing_bytes = head.canonical_signing_bytes()?;
        head.signature = Some(kp.multi_sig(&signing_bytes));
    }

    let resp = client
        .post(format!("{}/api/sites/{}/{}/head", base, fp, site))
        .header(reqwest::header::CONTENT_TYPE, "application/octet-stream")
        .body(serde_json::to_vec(&head)?)
        .send()
        .await
        .context("HEAD update request failed")?;

    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();
    if status == reqwest::StatusCode::CONFLICT {
        bail!(
            "HEAD update rejected: sequence {} is not greater than the server's current sequence — \
             pass a higher --sequence",
            sequence
        );
    }
    if status != reqwest::StatusCode::OK {
        bail!("HEAD update failed ({}): {}", status, text.trim());
    }
    let parsed: HeadResponse = serde_json::from_str(&text)
        .with_context(|| format!("unexpected HEAD response: {}", text.trim()))?;
    Ok(parsed.sequence)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// Vectors captured from the Elixir implementation by evaluating
    /// `Mjolnir.Sites.Crypto` / `Manifest.canonical_signing_bytes/1` directly.
    ///
    /// These pin the primitives; `sites_crossimpl_fixtures` +
    /// `scripts/sites_crossimpl_check.exs` prove the whole envelope round-trips
    /// through Elixir and verifies.
    const ELIXIR_HKDF_SEED0_INFO_A_HTML: &str =
        "3982EC826016D25B3E2600C6A910F9080D200224C30B30180ADEEEE5B7690432";
    const ELIXIR_XCHACHA_KEY7_NONCE9_HELLO: &str = "1ABA233EDBF8168377FFA0";
    const ELIXIR_HASH_HELLO_WORLD: &str = "DULfJyE3WQqNxy3ymuhAChyNR3yufT88pmqvAazKFMG4";
    const ELIXIR_MANIFEST_SIGNING_BYTES: &str = concat!(
        r#"{"created_at":"2026-07-21T12:34:56Z","entries":[{"bao_hash":"H","ciphertext_size":5,"#,
        r#""content_encoding":null,"content_type":"text/html; charset=utf-8","#,
        r#""nonce":"AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB","path":"/a.html","plaintext_size":5,"#,
        r#""wrapped_key":null}],"identikey_fp":"FP","mode":"public","signatures":null,"#,
        r#""site_name":"blog","sym_seed":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","version":1}"#
    );
    const ELIXIR_HEAD_SIGNING_BYTES: &str = concat!(
        r#"{"created_at":"2026-07-21T12:34:56Z","identikey_fp":"FP","sequence":3,"#,
        r#""signature":null,"site_name":"blog","snapshot_hash":"SH","version":1}"#
    );

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{:02X}", b)).collect()
    }

    fn sample_manifest() -> Manifest {
        Manifest {
            created_at: "2026-07-21T12:34:56Z".into(),
            entries: vec![Entry {
                bao_hash: "H".into(),
                ciphertext_size: 5,
                content_encoding: None,
                content_type: "text/html; charset=utf-8".into(),
                nonce: b64(&[1u8; 24]),
                path: "/a.html".into(),
                plaintext_size: 5,
                wrapped_key: None,
            }],
            identikey_fp: "FP".into(),
            mode: "public".into(),
            signatures: None,
            site_name: "blog".into(),
            sym_seed: b64(&[0u8; 32]),
            version: 1,
        }
    }

    fn sample_head() -> HeadRecord {
        HeadRecord {
            created_at: "2026-07-21T12:34:56Z".into(),
            identikey_fp: "FP".into(),
            sequence: 3,
            signature: None,
            site_name: "blog".into(),
            snapshot_hash: "SH".into(),
            version: 1,
        }
    }

    fn scratch_dir(tag: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        p.push(format!("mj-sites-test-{}-{}", tag, nanos));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    fn write_file(path: &Path, contents: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut f = std::fs::File::create(path).unwrap();
        f.write_all(contents.as_bytes()).unwrap();
    }

    // --- Crypto vectors ---

    #[test]
    fn hkdf_matches_elixir_vector() {
        let out = crypto::hkdf_sha256(&[0u8; 32], b"/a.html", 32);
        assert_eq!(hex(&out), ELIXIR_HKDF_SEED0_INFO_A_HTML);
    }

    #[test]
    fn hkdf_spans_multiple_expand_blocks() {
        // 32 bytes is one HMAC block; 100 forces four rounds of expansion and
        // a truncation, exercising the loop the publisher never hits itself.
        let long = crypto::hkdf_sha256(&[0u8; 32], b"/a.html", 100);
        assert_eq!(long.len(), 100);
        assert_eq!(hex(&long[..32]), ELIXIR_HKDF_SEED0_INFO_A_HTML);
    }

    #[test]
    fn xchacha20_matches_elixir_vector() {
        let ct = crypto::xchacha20_xor(&[7u8; 32], &[9u8; 24], b"hello world");
        assert_eq!(hex(&ct), ELIXIR_XCHACHA_KEY7_NONCE9_HELLO);
    }

    #[test]
    fn xchacha20_round_trips_across_block_boundaries() {
        // 200 bytes spans four 64-byte keystream blocks, so a broken counter
        // shows up as corruption past the first block.
        let plaintext: Vec<u8> = (0..200u32).map(|i| (i % 251) as u8).collect();
        let ct = crypto::xchacha20_xor(&[3u8; 32], &[4u8; 24], &plaintext);
        assert_ne!(ct, plaintext);
        assert_eq!(
            crypto::xchacha20_xor(&[3u8; 32], &[4u8; 24], &ct),
            plaintext
        );
    }

    #[test]
    fn content_hash_base58_matches_elixir_vector() {
        assert_eq!(
            crypto::content_hash_base58(b"hello world"),
            ELIXIR_HASH_HELLO_WORLD
        );
    }

    #[test]
    fn base58_drops_leading_zero_bytes_like_elixir() {
        // `Crypto.base58_encode(<<0,0,1,2>>)` is "5T" — the leading zeros are
        // absorbed by the integer conversion rather than encoded as '1's, which
        // is why the `bs58` crate cannot be used here.
        assert_eq!(crypto::base58_encode(&[0, 0, 1, 2]), "5T");
        assert_eq!(crypto::base58_encode(&[]), "");
        assert_eq!(crypto::base58_encode(&[0]), "");
    }

    // --- Canonical bytes ---

    #[test]
    fn manifest_signing_bytes_match_elixir() {
        let bytes = sample_manifest().canonical_signing_bytes().unwrap();
        assert_eq!(
            String::from_utf8(bytes).unwrap(),
            ELIXIR_MANIFEST_SIGNING_BYTES
        );
    }

    #[test]
    fn head_signing_bytes_match_elixir() {
        let bytes = sample_head().canonical_signing_bytes().unwrap();
        assert_eq!(String::from_utf8(bytes).unwrap(), ELIXIR_HEAD_SIGNING_BYTES);
    }

    #[test]
    fn signing_bytes_null_the_signature_rather_than_omitting_it() {
        let mut manifest = sample_manifest();
        manifest.signatures = Some(MultiSig {
            ed25519: "AAAA".into(),
        });
        let signed = String::from_utf8(serde_json::to_vec(&manifest).unwrap()).unwrap();
        assert!(
            signed.contains(r#""signatures":{"ed25519":"AAAA"}"#),
            "{}",
            signed
        );
        // Clearing must restore the exact unsigned form, not drop the key.
        let cleared = String::from_utf8(manifest.canonical_signing_bytes().unwrap()).unwrap();
        assert_eq!(cleared, ELIXIR_MANIFEST_SIGNING_BYTES);
    }

    // --- Keypair ---

    #[test]
    fn keypair_json_round_trips() {
        let kp = Keypair::generate();
        let loaded = Keypair::from_json(&kp.to_json().unwrap()).unwrap();
        assert_eq!(loaded.secret, kp.secret);
        assert_eq!(loaded.public, kp.public);
        assert_eq!(loaded.fingerprint(), kp.fingerprint());
    }

    #[test]
    fn keypair_rejects_mismatched_public_key() {
        let kp = Keypair::generate();
        let other = Keypair::generate();
        let json = serde_json::to_string(&KeypairJson {
            ed25519_public: b64(&other.public),
            ed25519_secret: b64(&kp.secret),
        })
        .unwrap();
        assert!(Keypair::from_json(&json).is_err());
    }

    #[test]
    fn signature_verifies_under_the_public_key() {
        use ed25519_dalek::Verifier;
        let kp = Keypair::generate();
        let sig = kp.sign(b"canonical bytes");
        let vk = ed25519_dalek::VerifyingKey::from_bytes(&kp.public).unwrap();
        assert!(vk
            .verify(
                b"canonical bytes",
                &ed25519_dalek::Signature::from_bytes(&sig)
            )
            .is_ok());
    }

    // --- Framing ---

    #[test]
    fn frame_chunk_uses_big_endian_u64_prefixes() {
        let framed = frame_chunk(b"abc", b"");
        assert_eq!(
            framed,
            vec![0, 0, 0, 0, 0, 0, 0, 3, b'a', b'b', b'c', 0, 0, 0, 0, 0, 0, 0, 0]
        );
    }

    #[test]
    fn frame_chunk_carries_a_non_empty_outboard() {
        let framed = frame_chunk(b"ct", b"ob");
        assert_eq!(&framed[..8], &2u64.to_be_bytes());
        assert_eq!(&framed[8..10], b"ct");
        assert_eq!(&framed[10..18], &2u64.to_be_bytes());
        assert_eq!(&framed[18..], b"ob");
    }

    // --- Directory walk ---

    #[test]
    fn walk_produces_sorted_rooted_paths_for_all_files() {
        let root = scratch_dir("walk");
        write_file(&root.join("index.html"), "home");
        write_file(&root.join("assets/app.css"), "body{}");
        write_file(&root.join("assets/deep/nested/x.js"), "1");
        write_file(&root.join(".well-known/acme"), "token"); // dotfile: kept
        write_file(&root.join("build/out.js"), "built"); // no gitignore filtering
        std::fs::create_dir_all(root.join("empty")).unwrap();

        let files = collect_files(&root).unwrap();
        let rels: Vec<String> = files.iter().map(|(_, r)| r.clone()).collect();

        assert_eq!(
            rels,
            vec![
                "/.well-known/acme",
                "/assets/app.css",
                "/assets/deep/nested/x.js",
                "/build/out.js",
                "/index.html",
            ]
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn snapshot_entries_are_encrypted_and_decryptable_from_the_manifest() {
        let root = scratch_dir("snapshot");
        write_file(&root.join("index.html"), "<h1>hi</h1>");
        write_file(&root.join("a.txt"), "plain");

        let seed = [42u8; 32];
        let (manifest, chunks) = build_snapshot(&root, "FP", "blog", None, seed).unwrap();

        assert_eq!(manifest.entries.len(), 2);
        assert_eq!(manifest.mode, "public");
        assert_eq!(manifest.signatures, None);
        assert_eq!(manifest.entries[0].path, "/a.txt");
        assert_eq!(
            manifest.entries[0].content_type,
            "text/plain; charset=utf-8"
        );
        assert_eq!(manifest.entries[1].path, "/index.html");
        assert_eq!(manifest.entries[1].content_type, "text/html; charset=utf-8");

        // Replay the reader's path: derive the key from the seed + entry path,
        // decrypt the chunk the manifest points at, and expect the original.
        for (entry, (hash, chunk)) in manifest.entries.iter().zip(chunks.iter()) {
            assert_eq!(&entry.bao_hash, hash);
            assert_eq!(entry.ciphertext_size, chunk.ciphertext.len());
            assert_eq!(
                crypto::content_hash_base58(&chunk.ciphertext),
                entry.bao_hash
            );

            let key: [u8; 32] = crypto::hkdf_sha256(&seed, entry.path.as_bytes(), 32)
                .try_into()
                .unwrap();
            let nonce = decode_b64_fixed::<24>(&entry.nonce, "nonce").unwrap();
            let plaintext = crypto::xchacha20_xor(&key, &nonce, &chunk.ciphertext);
            assert_eq!(plaintext.len(), entry.plaintext_size);

            let expected = std::fs::read(root.join(entry.path.trim_start_matches('/'))).unwrap();
            assert_eq!(plaintext, expected);
        }
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn signed_snapshot_signature_covers_the_cleared_manifest() {
        use ed25519_dalek::Verifier;
        let root = scratch_dir("signed");
        write_file(&root.join("index.html"), "hi");

        let kp = Keypair::generate();
        let (manifest, _) =
            build_snapshot(&root, &kp.fingerprint(), "blog", Some(&kp), [1u8; 32]).unwrap();

        let sig_b64 = manifest.signatures.clone().expect("signed").ed25519;
        let sig = decode_b64_fixed::<64>(&sig_b64, "sig").unwrap();
        let signing_bytes = manifest.canonical_signing_bytes().unwrap();
        let vk = ed25519_dalek::VerifyingKey::from_bytes(&kp.public).unwrap();
        assert!(vk
            .verify(&signing_bytes, &ed25519_dalek::Signature::from_bytes(&sig))
            .is_ok());
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn mime_sniffing_mirrors_the_elixir_table() {
        assert_eq!(mime_of("/a.html"), "text/html; charset=utf-8");
        assert_eq!(mime_of("/a.css"), "text/css; charset=utf-8");
        assert_eq!(mime_of("/a.js"), "application/javascript");
        assert_eq!(mime_of("/a.json"), "application/json");
        assert_eq!(mime_of("/a.svg"), "image/svg+xml");
        assert_eq!(mime_of("/a.png"), "image/png");
        assert_eq!(mime_of("/a.jpg"), "image/jpeg");
        assert_eq!(mime_of("/a.jpeg"), "image/jpeg");
        assert_eq!(mime_of("/a.txt"), "text/plain; charset=utf-8");
        assert_eq!(mime_of("/a.wasm"), "application/octet-stream");
        assert_eq!(mime_of("/LICENSE"), "application/octet-stream");
    }

    #[test]
    fn timestamps_have_no_subsecond_component() {
        let now = now_iso8601();
        assert_eq!(now.len(), 20, "{}", now);
        assert!(now.ends_with('Z'), "{}", now);
        assert!(!now.contains('.'), "{}", now);
    }

    /// Emit signed envelopes for the Elixir cross-implementation checker.
    ///
    /// This is the Rust half of the compatibility proof: it writes a keypair, a
    /// signed manifest and a signed HEAD record into `MJ_SITES_FIXTURE_DIR`,
    /// which `scripts/sites_crossimpl_check.exs` then parses and verifies with
    /// the real `Mjolnir.Sites` modules. Without that env var the test is a
    /// no-op, so `cargo test` stays hermetic.
    #[test]
    fn sites_crossimpl_fixtures() {
        let Ok(dir) = std::env::var("MJ_SITES_FIXTURE_DIR") else {
            return;
        };
        let dir = PathBuf::from(dir);
        std::fs::create_dir_all(&dir).unwrap();

        let site_root = dir.join("site");
        write_file(&site_root.join("index.html"), "<h1>worldtree</h1>");
        write_file(&site_root.join("assets/app.css"), "body{margin:0}");
        write_file(&site_root.join("data.json"), r#"{"ok":true}"#);

        let kp = Keypair::generate();
        let fp = kp.fingerprint();
        let (manifest, chunks) =
            build_snapshot(&site_root, &fp, "blog", Some(&kp), [77u8; 32]).unwrap();
        let manifest_bytes = serde_json::to_vec(&manifest).unwrap();

        let snapshot_hash = crypto::content_hash_base58(&manifest_bytes);
        let mut head = HeadRecord {
            created_at: now_iso8601(),
            identikey_fp: fp.clone(),
            sequence: 7,
            signature: None,
            site_name: "blog".into(),
            snapshot_hash: snapshot_hash.clone(),
            version: 1,
        };
        head.signature = Some(kp.multi_sig(&head.canonical_signing_bytes().unwrap()));

        std::fs::write(dir.join("keypair.json"), kp.to_json().unwrap()).unwrap();
        std::fs::write(dir.join("manifest.json"), &manifest_bytes).unwrap();
        std::fs::write(dir.join("head.json"), serde_json::to_vec(&head).unwrap()).unwrap();
        std::fs::write(
            dir.join("identity.json"),
            serde_json::to_vec(&serde_json::json!({ "pubkey": b64(&kp.public) })).unwrap(),
        )
        .unwrap();

        // Ciphertexts, so Elixir can re-derive each key and decrypt.
        let chunk_dir = dir.join("chunks");
        std::fs::create_dir_all(&chunk_dir).unwrap();
        for (hash, chunk) in &chunks {
            std::fs::write(chunk_dir.join(hash), &chunk.ciphertext).unwrap();
        }

        std::fs::write(
            dir.join("meta.json"),
            serde_json::to_vec(&serde_json::json!({
                "identikey_fp": fp,
                "site_name": "blog",
                "snapshot_hash": snapshot_hash,
                "sym_seed": b64(&[77u8; 32]),
                "site_root": site_root.to_string_lossy(),
            }))
            .unwrap(),
        )
        .unwrap();
    }
}
