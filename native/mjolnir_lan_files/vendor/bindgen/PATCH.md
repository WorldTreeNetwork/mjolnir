# bindgen 0.71.1 compatibility backport

Source: the crates.io `bindgen` 0.71.1 release, checksum
`5f58bf3d7db68cfbac37cfc485a8d711e87e064c3d0fe0435b92f7a407f9d6b3`.
The upstream BSD license is retained in `LICENSE`.

Only `Type::declaration` in `clang.rs` differs from that release. It includes
the type completeness fix from rust-lang/rust-bindgen#3278 (released in
0.72.1): https://github.com/rust-lang/rust-bindgen/pull/3278/files

Clang 22 and newer may return a forward declaration rather than a definition.
Resolve that cursor before inspecting fields. Otherwise oqs-sys generates an
empty OQS_SIG despite computing the full C layout, and its layout assertion
fails. Layout assertions remain enabled.

oqs-sys 0.11 restricts bindgen to 0.71, so a lockfile update alone cannot select
0.72.1. The native workspace patch backports this fix without patching sibling
checkouts, vendoring liboqs, or removing PQ verification. Remove this copy when
the crypto dependency graph accepts a bindgen release containing the fix.
