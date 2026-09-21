//! Blob door: HTTP put/get over recrypt `blob/b3/{base58}` keys.
//!
//! Callers never hold B2 credentials. Accepted means the canonical
//! store has the object (HeadObject/GET), not that PutObject returned 200.
//! Host disk is a write-through cache, not the archive.

pub mod cache;
pub mod http;
pub mod memory;
pub mod pump;
pub mod put;
pub mod s3;
pub mod store;

pub use cache::DiskCache;
pub use http::{router, AppState};
pub use memory::MemoryStore;
pub use put::{put_file, PutError};
pub use store::{BlobStream, CanonicalStore, StoreError};

/// Default bind — same port Sites planned for the recrypt sidecar.
pub const DEFAULT_BIND: &str = "127.0.0.1:7222";

/// Safety rail, not a product limit. Disk is the real cap (507 on ENOSPC).
pub const DEFAULT_MAX_BYTES: u64 = 1 << 40; // 1 TiB

/// Working-set cache budget on the host SSD.
pub const DEFAULT_CACHE_BYTES: u64 = 64 << 30; // 64 GiB

/// Production cache root. Lives **outside** `btrfs_root` so VM / named
/// snapshots cannot pin cache extents (same reason escrow is not on the
/// data volume). Wiping this dir does not lose accepted objects.
pub const DEFAULT_CACHE_DIR: &str = "/var/lib/mjolnir/blobs";

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
