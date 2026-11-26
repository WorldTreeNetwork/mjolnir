//! Route (b) prototype: the relay verifies the JWT itself, takes the `kind` claim out of the verified
//! payload, and hands moq-auth's strict `Claims` decoder everything else. Not product code.
//!
//! Steps, each mirroring `moq_auth::KeySet::verify` at 4a6f522 (`set.rs:130-150`, `key.rs:615-650`):
//!  1. Header: `kid` required (the relay's key loader already requires a kid on every key), key found
//!     by kid, header `alg` equal to the key's algorithm, key permits Verify, key has no scope (mint
//!     keys have none; refusing is stricter than re-implementing scope checks).
//!  2. Signature: `jsonwebtoken::decode` with the same `Validation` moq-auth builds (no spec claims
//!     required, exp/nbf/aud not checked by jsonwebtoken) and rind as the crypto provider.
//!  3. Payload: read as a JSON object only, refusing a repeated member (as serde's derive does in
//!     moq-auth's wire decoder), take `kind` out, decode the rest with `moq_auth::Claims`
//!     (`deny_unknown_fields`, so any other unknown claim is still refused), then `Claims::validate`.
//!  4. Times: refuse `exp <= now` and `nbf > now` (moq-auth `validate_times`), on `kio::clock::wall()`.
use std::collections::BTreeMap;
use std::fmt;

use base64::Engine;
use moq_auth::{Claims, KeyMaterial, KeyOperation, KeySet};
use serde::de::{Deserialize, Deserializer, MapAccess, Visitor};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RoomKind {
    Open,
    Protected,
}

#[derive(Debug)]
pub enum ClaimRefuse {
    Header(&'static str),
    Signature(String),
    Payload(String),
    Kind(String),
    Times(&'static str),
}

/// The verified payload as members, repeated members refused.
struct Members(BTreeMap<String, serde_json::Value>);

impl<'de> Deserialize<'de> for Members {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V;
        impl<'de> Visitor<'de> for V {
            type Value = Members;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("an object")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Members, A::Error> {
                let mut out = BTreeMap::new();
                while let Some((k, v)) = map.next_entry::<String, serde_json::Value>()? {
                    if out.contains_key(&k) {
                        return Err(serde::de::Error::custom(format!("duplicate field `{k}`")));
                    }
                    out.insert(k, v);
                }
                Ok(Members(out))
            }
        }
        d.deserialize_map(V)
    }
}

pub fn install_provider() {
    let _ = rind_jsonwebtoken::default_provider().map(|p| p.install_default());
}

pub fn verify_room(set: &KeySet, token: &str) -> Result<(Claims, RoomKind), ClaimRefuse> {
    let header = jsonwebtoken::decode_header(token).map_err(|_| ClaimRefuse::Header("undecodable header"))?;
    let kid = header.kid.as_deref().ok_or(ClaimRefuse::Header("no kid"))?;
    let key = set.find(kid).ok_or(ClaimRefuse::Header("unknown kid"))?;
    let alg: jsonwebtoken::Algorithm = key.algorithm.into();
    if header.alg != alg {
        return Err(ClaimRefuse::Header("alg differs from the key's"));
    }
    if !key.operations.contains(&KeyOperation::Verify) {
        return Err(ClaimRefuse::Header("key does not verify"));
    }
    if key.scope.is_some() {
        return Err(ClaimRefuse::Header("scoped key"));
    }
    let b64 = |b: &[u8]| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(b);
    let decoding = match &key.material {
        KeyMaterial::OKP { x, .. } => jsonwebtoken::DecodingKey::from_ed_components(&b64(x)),
        KeyMaterial::EC { x, y, .. } => jsonwebtoken::DecodingKey::from_ec_components(&b64(x), &b64(y)),
        _ => return Err(ClaimRefuse::Header("key type not allowed")),
    }
    .map_err(|e| ClaimRefuse::Signature(e.to_string()))?;
    let mut validation = jsonwebtoken::Validation::new(alg);
    validation.required_spec_claims = Default::default();
    validation.validate_exp = false;
    validation.validate_nbf = false;
    validation.validate_aud = false;
    let data = jsonwebtoken::decode::<Members>(token, &decoding, &validation)
        .map_err(|e| ClaimRefuse::Signature(e.to_string()))?;
    let mut members = data.claims.0;
    let kind = match members.remove("kind") {
        None => RoomKind::Protected,
        Some(serde_json::Value::String(s)) if s == "open" => RoomKind::Open,
        Some(serde_json::Value::String(s)) if s == "protected" => RoomKind::Protected,
        Some(other) => return Err(ClaimRefuse::Kind(other.to_string())),
    };
    let object = serde_json::Value::Object(members.into_iter().collect());
    let claims: Claims = serde_json::from_value(object).map_err(|e| ClaimRefuse::Payload(e.to_string()))?;
    claims.validate().map_err(|e| ClaimRefuse::Payload(e.to_string()))?;
    let now = kio::clock::wall();
    if claims.expires.is_some_and(|exp| exp <= now) {
        return Err(ClaimRefuse::Times("expired"));
    }
    if claims.not_before.is_some_and(|nbf| nbf > now) {
        return Err(ClaimRefuse::Times("not yet valid"));
    }
    Ok((claims, kind))
}

/// `mjolnir_relay::assess` with `keys.verify` replaced by `verify_room`. Same order otherwise.
pub fn assess_room(
    token: Option<&str>,
    path: &str,
    keys: &KeySet,
    max_ttl: std::time::Duration,
) -> Result<(moq_auth::Grant, RoomKind), String> {
    let raw = mjolnir_relay::request_path(path);
    let token = token.filter(|t| !t.is_empty()).ok_or("no token")?;
    if !raw.is_empty() && !mjolnir_relay::tenant_path(raw) {
        return Err("ticket path".into());
    }
    let (claims, kind) = verify_room(keys, token).map_err(|e| format!("{e:?}"))?;
    mjolnir_relay::profile(&claims, max_ttl, kio::clock::wall()).map_err(|e| format!("Profile({e})"))?;
    if !raw.is_empty() && !(raw == claims.root || raw.starts_with(&format!("{}/", claims.root))) {
        return Err("Profile(path outside the grant)".into());
    }
    let grant = mjolnir_relay::grant_from(&claims).map_err(|e| format!("{e:?}"))?;
    Ok((grant, kind))
}
