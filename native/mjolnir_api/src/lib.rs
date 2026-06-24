//! Shared Mjolnir client core: the host-API **data layer** (typed response
//! structs + authenticated HTTP helpers) and the **OIDC token store** (device
//! flow + `~/.config/mjolnir/token.json`).
//!
//! This crate is the single owner of the Mjolnir API surface. Both the
//! `mjolnir` CLI bin and external apps (e.g. Papyrus) link it as a path dep so
//! querying and auth live in one place. The CLI keeps its presentation/command
//! layer (`cmd_*`, profiles, connect) on top of this; this crate intentionally
//! holds nothing that prints or depends on CLI config/connect machinery.

pub mod api;
pub mod auth;
pub mod config;
