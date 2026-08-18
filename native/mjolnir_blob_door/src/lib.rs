//! Blob door: HTTP put/get over recrypt `blob/b3/{base58}` keys.
//!
//! Callers never hold B2 credentials. Accepted means the canonical
//! store has the object (HeadObject/GET), not that PutObject returned 200.

pub mod http;
pub mod memory;
pub mod put;
pub mod s3;
pub mod store;

pub use http::{router, AppState};
pub use memory::MemoryStore;
pub use put::{put_bytes, put_outboard, PutError};
pub use store::{CanonicalStore, StoreError};

/// Default bind — same port Sites planned for the recrypt sidecar.
pub const DEFAULT_BIND: &str = "127.0.0.1:7222";

/// v1 in-memory ceiling. Streaming multipart is a later slice.
pub const DEFAULT_MAX_BYTES: usize = 64 * 1024 * 1024;

pub fn hash_to_base58(bytes: &[u8; 32]) -> String {
    bs58::encode(bytes).into_string()
}

pub fn hash_from_base58(s: &str) -> Option<[u8; 32]> {
    let bytes = bs58::decode(s).into_vec().ok()?;
    bytes.try_into().ok()
}

pub fn blake3_bytes(data: &[u8]) -> [u8; 32] {
    *blake3::hash(data).as_bytes()
}
