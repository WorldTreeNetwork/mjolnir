//! Auth now lives in the shared `mjolnir-api` crate. This thin re-export keeps
//! existing `crate::auth::*` paths (main.rs, connect.rs, api.rs) working
//! unchanged while the device-flow + token store are owned in one place.

pub use mjolnir_api::auth::*;
