//! Direct identity verification and same-holder session binding.
//!
//! Adapters supply authenticated edge/channel inputs; none may come from the
//! submitted bind. Endpoint storage implements [`IssuanceStore`], including the
//! durable transaction. This module does not expose a pre-commit credential.

use identikey_auth::{
    error::AuthError, verify_classical, verify_response, Challenge, ClassicalPublicKey,
    ClassicalSignature, NonceStore, Response, Verified, VerifyPolicy,
};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("identity: {0}")]
    Identity(#[from] AuthError),
    #[error("authenticated peer does not prove the pinned edge")]
    WrongEdge,
    #[error("authenticated channel unavailable or different")]
    Channel,
    #[error("invalid session bind")]
    Bind,
    #[error("local policy denied the request")]
    Policy,
    #[error("issuance transaction failed: {0}")]
    Commit(String),
}

/// Canonical operation/resource tuple. Components are exact, nonempty printable
/// ASCII tokens (no whitespace or normalization). E.g. ["vms", "stop"] and
/// ["vm", "id"]. Component boundaries are signed, so joining is unnecessary.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CanonicalTuple(Vec<String>);

impl CanonicalTuple {
    pub fn new(parts: impl IntoIterator<Item = impl Into<String>>) -> Result<Self, Error> {
        let parts: Vec<String> = parts.into_iter().map(Into::into).collect();
        if parts.is_empty()
            || parts
                .iter()
                .any(|s| s.is_empty() || !s.bytes().all(|b| (0x21..=0x7e).contains(&b)))
        {
            return Err(Error::Bind);
        }
        Ok(Self(parts))
    }

    pub fn parts(&self) -> &[String] {
        &self.0
    }
}

/// The second signed object; no holder public key is accepted here. Verification
/// always uses the classical key authenticated by the v1 Response.
#[derive(Clone, Debug)]
pub struct SessionBind {
    pub session_public_key: ClassicalPublicKey,
    pub operation: CanonicalTuple,
    pub resource: CanonicalTuple,
    pub channel: [u8; 32],
    pub signature: ClassicalSignature,
}

/// Canonical CBOR ["identikey-mjolnir/v1", "bind", challenge bstr,
/// session-public-key map, operation tuple, resource tuple, channel bstr].
/// The challenge is verbatim; its v1 serialization belongs to identikey-auth.
pub fn bind_signing_bytes(
    challenge_bytes: &[u8],
    session_public_key: &ClassicalPublicKey,
    operation: &CanonicalTuple,
    resource: &CanonicalTuple,
    channel: &[u8; 32],
) -> Vec<u8> {
    let mut out = vec![0x87];
    cbor_string(3, b"identikey-mjolnir/v1", &mut out);
    cbor_string(3, b"bind", &mut out);
    cbor_string(2, challenge_bytes, &mut out);
    out.extend(session_public_key.to_value().to_bytes());
    for tuple in [operation, resource] {
        cbor_head(4, tuple.0.len() as u64, &mut out);
        for part in &tuple.0 {
            cbor_string(3, part.as_bytes(), &mut out);
        }
    }
    cbor_string(2, channel, &mut out);
    out
}

// Only the new bind's array/text/byte-string framing. No v1 codec or parser.
fn cbor_string(major: u8, bytes: &[u8], out: &mut Vec<u8>) {
    cbor_head(major, bytes.len() as u64, out);
    out.extend_from_slice(bytes);
}

fn cbor_head(major: u8, n: u64, out: &mut Vec<u8>) {
    let tag = major << 5;
    match n {
        0..=23 => out.push(tag | n as u8),
        24..=255 => out.extend([tag | 24, n as u8]),
        256..=65535 => {
            out.push(tag | 25);
            out.extend((n as u16).to_be_bytes());
        }
        65536..=0xffff_ffff => {
            out.push(tag | 26);
            out.extend((n as u32).to_be_bytes());
        }
        _ => {
            out.push(tag | 27);
            out.extend(n.to_be_bytes());
        }
    }
}

/// Trusted adapter inputs, after verification of the operational edge proof.
/// `proven_edge_xid` is the proof's verified pin, never an advertised audience.
/// For Iroh, `peer_node_id` must be the node authenticated by that edge proof.
/// HTTPS inputs must come exclusively from the gateway's trusted backend hop.
#[derive(Clone, Copy)]
pub enum AuthenticatedChannel<'a> {
    Https {
        proven_edge_xid: &'a str,
        origin_spki: &'a [u8],
        server_conn_id: &'a [u8],
    },
    Iroh {
        proven_edge_xid: &'a str,
        peer_node_id: &'a [u8; 32],
        conn_id: &'a [u8],
    },
}

impl AuthenticatedChannel<'_> {
    pub fn binding(&self, pinned_edge_xid: &str) -> Result<[u8; 32], Error> {
        let (proven, peer, conn): (&str, &[u8], &[u8]) = match self {
            Self::Https {
                proven_edge_xid,
                origin_spki,
                server_conn_id,
            } => (proven_edge_xid, origin_spki, server_conn_id),
            Self::Iroh {
                proven_edge_xid,
                peer_node_id,
                conn_id,
            } => (proven_edge_xid, peer_node_id.as_slice(), conn_id),
        };
        if pinned_edge_xid.is_empty() || proven != pinned_edge_xid {
            return Err(Error::WrongEdge);
        }
        if peer.is_empty() || conn.is_empty() {
            return Err(Error::Channel);
        }
        let mut bytes = Vec::with_capacity(peer.len() + conn.len());
        bytes.extend_from_slice(peer);
        bytes.extend_from_slice(conn);
        Ok(crate::blake3_hash(&bytes))
    }
}

/// Fully verified authority passed to local policy and then atomic issuance.
/// Fields are private so callers cannot construct a grant without verification.
#[derive(Clone, Debug)]
pub struct AuthorizedSession {
    identity: Verified,
    edge_xid: String,
    bind: SessionBind,
}

impl AuthorizedSession {
    pub fn identity(&self) -> &Verified {
        &self.identity
    }
    pub fn edge_xid(&self) -> &str {
        &self.edge_xid
    }
    pub fn bind(&self) -> &SessionBind {
        &self.bind
    }
}

/// Implemented by endpoint storage, not a standalone nonce burner.
///
/// `check_issued` is read-only and must check the EXACT issued challenge bytes,
/// nonce, expiry, and unused state. Missing/lost state fails closed.
/// `commit` MUST recheck those conditions under the same transaction/lock as
/// credential issuance, durably record both consumption and the credential, and
/// return only after commit. A concurrent loser returns NonceReplay. Any error
/// before commit leaves both unchanged. Never publish usable credentials before
/// commit. Recovery restores the combined record; delivery loss cannot undo it.
/// Mint only the session key and operation/resource in `grant` (login profile).
/// The HTTP endpoints node supplies the durable backend and credential profile.
pub trait IssuanceStore: Sync {
    type Credential;
    fn check_issued(&self, challenge_bytes: &[u8], now: u64) -> Result<(), Error>;
    fn commit(
        &self,
        challenge_bytes: &[u8],
        now: u64,
        grant: &AuthorizedSession,
    ) -> Result<Self::Credential, Error>;
}

/// Transaction-scoped adapter: upstream's consume only stages a validated nonce.
/// Dropping it (including on bad bind/policy) has no persistent effect.
struct StagedNonce<'a, S> {
    store: &'a S,
    bytes: &'a [u8],
    nonce: &'a [u8],
    staged: bool,
}

impl<S: IssuanceStore> NonceStore for StagedNonce<'_, S> {
    fn record_issued(&mut self, _: &[u8], _: u64) {
        unreachable!("verification only")
    }
    fn gc(&mut self, _: u64) {
        unreachable!("verification only")
    }
    fn consume(&mut self, nonce: &[u8], now: u64) -> identikey_auth::error::Result<()> {
        if self.staged || nonce != self.nonce {
            return Err(AuthError::NonceReplay);
        }
        // Upstream only accepts AuthError here. Preserve replay/time errors;
        // storage failure still fails closed without staging or issuance.
        self.store
            .check_issued(self.bytes, now)
            .map_err(|e| match e {
                Error::Identity(e) => e,
                other => AuthError::Backend(other.to_string()),
            })?;
        self.staged = true;
        Ok(())
    }
}

pub struct VerificationContext<'a> {
    pub pinned_edge_xid: &'a str,
    pub channel: Option<AuthenticatedChannel<'a>>,
    pub now: u64,
    pub identity_policy: VerifyPolicy,
}

/// Verify identity, same-holder bind, current connection, and local policy;
/// finally commit nonce consumption and issuance together. There is no core,
/// OIDC, custody inference, or fallback on this path.
pub fn verify_and_issue<S: IssuanceStore>(
    response: &Response,
    bind: &SessionBind,
    context: &VerificationContext<'_>,
    store: &S,
    allow: impl FnOnce(&AuthorizedSession) -> bool,
) -> Result<S::Credential, Error> {
    let challenge = Challenge::from_bytes(&response.challenge_bytes)?;
    let mut nonce = StagedNonce {
        store,
        bytes: &response.challenge_bytes,
        nonce: &challenge.nonce,
        staged: false,
    };
    let identity = verify_response(
        response,
        context.pinned_edge_xid,
        context.now,
        0,
        context.identity_policy,
        &mut nonce,
    )?;
    let payload = bind_signing_bytes(
        &response.challenge_bytes,
        &bind.session_public_key,
        &bind.operation,
        &bind.resource,
        &bind.channel,
    );
    verify_classical(&identity.public_key, &payload, &bind.signature).map_err(|_| Error::Bind)?;
    // Reject malformed session-key lengths. Session possession and full key
    // validation for protected requests belong to the later login profile.
    let key_len = bind.session_public_key.bytes.len();
    match bind.session_public_key.alg {
        identikey_auth::ClassicalAlg::Ed25519 if key_len == 32 => {}
        identikey_auth::ClassicalAlg::P256 if key_len == 33 => {}
        _ => return Err(Error::Bind),
    }
    let channel = context.channel.as_ref().ok_or(Error::Channel)?;
    if channel.binding(context.pinned_edge_xid)? != bind.channel {
        return Err(Error::Channel);
    }
    let grant = AuthorizedSession {
        identity,
        edge_xid: context.pinned_edge_xid.to_owned(),
        bind: bind.clone(),
    };
    if !allow(&grant) {
        return Err(Error::Policy);
    }
    store.commit(&response.challenge_bytes, context.now, &grant)
}

#[cfg(test)]
mod direct_challenge_tests {
    use super::*;
    use identikey_auth::{ClassicalAlg, Signer, SoftwareSigner, VERSION};
    use std::{
        collections::HashMap,
        sync::{Arc, Barrier, Mutex},
    };

    const EDGE: &str = "pinned-stable-edge-xid";
    const NOW: u64 = 1_000;

    // Transaction model for the endpoint storage contract. Snapshot is the
    // last committed durable state, not a copy of a live staging adapter.
    #[derive(Clone, Default)]
    struct State {
        issued: HashMap<Vec<u8>, (u64, Option<AuthorizedSession>)>,
        credentials: Vec<Vec<u8>>,
    }

    #[derive(Default)]
    struct Store {
        state: Mutex<State>,
        fail_before_commit: Mutex<bool>,
        race: Option<Barrier>,
    }

    fn check(state: &State, bytes: &[u8], now: u64) -> Result<(), Error> {
        match state.issued.get(bytes) {
            Some((_, Some(_))) | None => Err(AuthError::NonceReplay.into()),
            Some((exp, None)) if now > *exp => Err(AuthError::TimeWindow.into()),
            Some(_) => Ok(()),
        }
    }

    impl Store {
        fn record(&self, challenge: &Challenge) {
            let old = self
                .state
                .lock()
                .unwrap()
                .issued
                .insert(challenge.to_bytes(), (challenge.expires_at, None));
            assert!(old.is_none(), "never reissue a consumed nonce");
        }
        fn count(&self) -> usize {
            self.state.lock().unwrap().credentials.len()
        }
        fn restart(&self) -> Self {
            Self {
                state: Mutex::new(self.state.lock().unwrap().clone()),
                ..Self::default()
            }
        }
    }

    impl IssuanceStore for Store {
        type Credential = Vec<u8>;
        fn check_issued(&self, bytes: &[u8], now: u64) -> Result<(), Error> {
            check(&self.state.lock().unwrap(), bytes, now)?;
            // Both contenders must finish identity before either can commit.
            if let Some(barrier) = &self.race {
                barrier.wait();
            }
            Ok(())
        }
        fn commit(
            &self,
            bytes: &[u8],
            now: u64,
            grant: &AuthorizedSession,
        ) -> Result<Vec<u8>, Error> {
            let mut state = self.state.lock().unwrap();
            check(&state, bytes, now)?;
            if *self.fail_before_commit.lock().unwrap() {
                return Err(Error::Commit("injected pre-commit loss".into()));
            }
            // A test credential is deliberately not a production login profile.
            // Stage both writes, then publish the entire committed state once.
            let mut next = state.clone();
            let credential =
                format!("committed-credential-{}", next.credentials.len()).into_bytes();
            next.issued.get_mut(bytes).unwrap().1 = Some(grant.clone());
            next.credentials.push(credential.clone());
            *state = next;
            Ok(credential)
        }
    }

    struct Fixture {
        signer: SoftwareSigner,
        response: Response,
        bind: SessionBind,
        challenge: Challenge,
        store: Store,
    }

    fn channel(conn: &[u8]) -> AuthenticatedChannel<'_> {
        AuthenticatedChannel::Https {
            proven_edge_xid: EDGE,
            origin_spki: b"served-origin-SPKI",
            server_conn_id: conn,
        }
    }

    fn context(conn: &[u8]) -> VerificationContext<'_> {
        VerificationContext {
            pinned_edge_xid: EDGE,
            channel: Some(channel(conn)),
            now: NOW,
            identity_policy: VerifyPolicy::PqOptional,
        }
    }

    impl Fixture {
        fn new(signer: SoftwareSigner) -> Self {
            let challenge = Challenge {
                version: VERSION,
                audience: EDGE.into(),
                nonce: vec![9; 16],
                issued_at: NOW,
                expires_at: NOW + 120,
            };
            let store = Store::default();
            store.record(&challenge);
            let response = signer.respond(&challenge).unwrap();
            let mut bind = SessionBind {
                session_public_key: SoftwareSigner::from_ed25519_seed([2; 32])
                    .classical_public_key(),
                operation: CanonicalTuple::new(["vms", "stop"]).unwrap(),
                resource: CanonicalTuple::new(["vm", "vm-A"]).unwrap(),
                channel: channel(b"N1").binding(EDGE).unwrap(),
                signature: signer.sign_classical(b"placeholder").unwrap(),
            };
            bind.signature = signer
                .sign_classical(&bind_signing_bytes(
                    &response.challenge_bytes,
                    &bind.session_public_key,
                    &bind.operation,
                    &bind.resource,
                    &bind.channel,
                ))
                .unwrap();
            Self {
                signer,
                response,
                bind,
                challenge,
                store,
            }
        }
        fn ed() -> Self {
            Self::new(SoftwareSigner::from_ed25519_seed([1; 32]))
        }
        fn run(&self) -> Result<Vec<u8>, Error> {
            verify_and_issue(
                &self.response,
                &self.bind,
                &context(b"N1"),
                &self.store,
                |_| true,
            )
        }
        fn resign_bind(&mut self) {
            self.bind.signature = self
                .signer
                .sign_classical(&bind_signing_bytes(
                    &self.response.challenge_bytes,
                    &self.bind.session_public_key,
                    &self.bind.operation,
                    &self.bind.resource,
                    &self.bind.channel,
                ))
                .unwrap();
        }
        fn assert_unused(&self) {
            assert_eq!(self.store.count(), 0);
            self.store
                .check_issued(&self.response.challenge_bytes, NOW)
                .unwrap();
        }
    }

    fn is_replay(result: Result<Vec<u8>, Error>) -> bool {
        matches!(result, Err(Error::Identity(AuthError::NonceReplay)))
    }

    #[test]
    fn direct_challenge_success_and_replay() {
        for signer in [
            SoftwareSigner::from_ed25519_seed([1; 32]),
            SoftwareSigner::from_p256_seed([1; 32]).unwrap(),
        ] {
            let f = Fixture::new(signer);
            // The external protocol types and wire roundtrip are unchanged.
            assert_eq!(
                Response::from_bytes(&f.response.to_bytes()).unwrap(),
                f.response
            );
            f.run().unwrap();
            assert_eq!(f.store.count(), 1);
            assert!(is_replay(f.run()));
            let state = f.store.state.lock().unwrap();
            let grant = state.issued[&f.response.challenge_bytes]
                .1
                .as_ref()
                .unwrap();
            assert_eq!(grant.edge_xid(), EDGE);
            assert_eq!(grant.identity().public_key, f.signer.classical_public_key());
            assert_eq!(grant.bind().session_public_key, f.bind.session_public_key);
            assert_eq!(grant.bind().operation, f.bind.operation);
            assert_eq!(grant.bind().resource, f.bind.resource);
        }
    }

    #[test]
    fn direct_challenge_unused_expiry() {
        let f = Fixture::ed();
        let mut ctx = context(b"N1");
        ctx.now = f.challenge.expires_at + 1;
        assert!(matches!(
            verify_and_issue(&f.response, &f.bind, &ctx, &f.store, |_| true),
            Err(Error::Identity(AuthError::TimeWindow))
        ));
        f.assert_unused();
    }

    #[test]
    fn direct_challenge_wrong_edge_with_correct_audience() {
        let f = Fixture::ed();
        let mut ctx = context(b"N1");
        ctx.channel = Some(AuthenticatedChannel::Https {
            proven_edge_xid: "wrong-peer-pin",
            origin_spki: b"served-origin-SPKI",
            server_conn_id: b"N1",
        });
        assert!(matches!(
            verify_and_issue(&f.response, &f.bind, &ctx, &f.store, |_| true),
            Err(Error::WrongEdge)
        ));
        f.assert_unused();
        f.run().unwrap();
    }

    #[test]
    fn direct_challenge_wrong_audience() {
        let mut f = Fixture::ed();
        f.challenge.audience = "another-edge".into();
        f.response = f.signer.respond(&f.challenge).unwrap();
        f.store.record(&f.challenge);
        f.resign_bind();
        assert!(matches!(f.run(), Err(Error::Identity(AuthError::Audience))));
        f.assert_unused();
    }

    #[test]
    fn direct_challenge_altered_request_and_holder_substitution() {
        for field in 0..5 {
            let mut f = Fixture::ed();
            let original = f.bind.clone();
            match field {
                0 => f.bind.operation = CanonicalTuple::new(["vms", "delete"]).unwrap(),
                1 => f.bind.resource = CanonicalTuple::new(["vm", "vm-B"]).unwrap(),
                2 => {
                    f.bind.session_public_key =
                        SoftwareSigner::from_ed25519_seed([3; 32]).classical_public_key()
                }
                3 => f.bind.channel[0] ^= 1,
                _ => {
                    f.bind.signature = SoftwareSigner::from_ed25519_seed([4; 32])
                        .sign_classical(&bind_signing_bytes(
                            &f.response.challenge_bytes,
                            &f.bind.session_public_key,
                            &f.bind.operation,
                            &f.bind.resource,
                            &f.bind.channel,
                        ))
                        .unwrap()
                }
            }
            assert!(matches!(f.run(), Err(Error::Bind)));
            f.assert_unused();
            f.bind = original;
            f.run().unwrap(); // Invalid bind never consumed the nonce.
        }
    }

    #[test]
    fn direct_challenge_bind_on_different_exchange() {
        let mut f = Fixture::ed();
        f.challenge.nonce = vec![8; 16];
        f.response = f.signer.respond(&f.challenge).unwrap();
        f.store.record(&f.challenge);
        assert!(matches!(f.run(), Err(Error::Bind)));
        f.assert_unused();
        f.resign_bind();
        f.run().unwrap();
    }

    #[test]
    fn direct_challenge_policy_denial_after_valid_signature() {
        let f = Fixture::ed();
        let mut called = false;
        assert!(matches!(
            verify_and_issue(&f.response, &f.bind, &context(b"N1"), &f.store, |grant| {
                called = true;
                assert_eq!(grant.identity().public_key, f.signer.classical_public_key());
                assert_eq!(grant.bind().operation.parts(), ["vms", "stop"]);
                false
            }),
            Err(Error::Policy)
        ));
        assert!(called);
        f.assert_unused();
        f.run().unwrap();
    }

    #[test]
    fn direct_challenge_transport_replay_n2_then_n1_then_replay() {
        let f = Fixture::ed();
        assert!(matches!(
            verify_and_issue(&f.response, &f.bind, &context(b"N2"), &f.store, |_| true),
            Err(Error::Channel)
        ));
        f.assert_unused();
        f.run().unwrap();
        assert!(is_replay(f.run()));
        assert_eq!(f.store.count(), 1);
    }

    #[test]
    fn direct_challenge_untrusted_or_missing_channel() {
        let f = Fixture::ed();
        let mut ctx = context(b"N1");
        // Untrusted hop fields are not converted to AuthenticatedChannel.
        ctx.channel = None;
        assert!(matches!(
            verify_and_issue(&f.response, &f.bind, &ctx, &f.store, |_| true),
            Err(Error::Channel)
        ));
        ctx.channel = Some(channel(b""));
        assert!(matches!(
            verify_and_issue(&f.response, &f.bind, &ctx, &f.store, |_| true),
            Err(Error::Channel)
        ));
        f.assert_unused();
    }

    #[test]
    fn direct_challenge_iroh_channel_and_peer() {
        let mut f = Fixture::ed();
        let node = [5; 32];
        let mut ctx = context(b"N1");
        ctx.channel = Some(AuthenticatedChannel::Iroh {
            proven_edge_xid: EDGE,
            peer_node_id: &node,
            conn_id: b"I1",
        });
        f.bind.channel = ctx.channel.unwrap().binding(EDGE).unwrap();
        f.resign_bind();
        ctx.channel = Some(AuthenticatedChannel::Iroh {
            proven_edge_xid: EDGE,
            peer_node_id: &node,
            conn_id: b"I2",
        });
        assert!(matches!(
            verify_and_issue(&f.response, &f.bind, &ctx, &f.store, |_| true),
            Err(Error::Channel)
        ));
        f.assert_unused();
        ctx.channel = Some(AuthenticatedChannel::Iroh {
            proven_edge_xid: "wrong-edge",
            peer_node_id: &node,
            conn_id: b"I1",
        });
        assert!(matches!(
            verify_and_issue(&f.response, &f.bind, &ctx, &f.store, |_| true),
            Err(Error::WrongEdge)
        ));
        ctx.channel = Some(AuthenticatedChannel::Iroh {
            proven_edge_xid: EDGE,
            peer_node_id: &node,
            conn_id: b"I1",
        });
        verify_and_issue(&f.response, &f.bind, &ctx, &f.store, |_| true).unwrap();
    }

    #[test]
    fn direct_challenge_pre_commit_failure_and_restart() {
        let f = Fixture::ed();
        *f.store.fail_before_commit.lock().unwrap() = true;
        assert!(matches!(f.run(), Err(Error::Commit(_))));
        f.assert_unused();
        let restored = f.store.restart();
        verify_and_issue(&f.response, &f.bind, &context(b"N1"), &restored, |_| true).unwrap();
        assert_eq!(restored.count(), 1);
    }

    #[test]
    fn direct_challenge_concurrent_duplicates_one_winner() {
        let mut f = Fixture::ed();
        f.store.race = Some(Barrier::new(2));
        let f = Arc::new(f);
        let handles: Vec<_> = (0..2)
            .map(|_| {
                let f = Arc::clone(&f);
                std::thread::spawn(move || f.run())
            })
            .collect();
        let results: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
        assert_eq!(
            results
                .into_iter()
                .filter(|r| matches!(r, Err(Error::Identity(AuthError::NonceReplay))))
                .count(),
            1
        );
        assert_eq!(f.store.count(), 1);
    }

    #[test]
    fn direct_challenge_post_commit_loss_and_restart() {
        let f = Fixture::ed();
        drop(f.run().unwrap()); // Commit succeeded, delivery was lost.
        assert!(is_replay(f.run()));
        let restored = f.store.restart();
        assert!(is_replay(verify_and_issue(
            &f.response,
            &f.bind,
            &context(b"N1"),
            &restored,
            |_| true
        )));
        assert!(is_replay(verify_and_issue(
            &f.response,
            &f.bind,
            &context(b"N2"),
            &restored,
            |_| true
        )));
        assert_eq!(restored.count(), 1);
    }

    #[test]
    fn direct_challenge_unknown_or_lost_store_and_altered_challenge() {
        let mut f = Fixture::ed();
        let empty = Store::default();
        assert!(is_replay(verify_and_issue(
            &f.response,
            &f.bind,
            &context(b"N1"),
            &empty,
            |_| true
        )));
        // Even a holder-signed change to expiry must not extend an issued nonce.
        f.challenge.expires_at += 60;
        f.response = f.signer.respond(&f.challenge).unwrap();
        f.resign_bind();
        assert!(is_replay(f.run()));
        assert_eq!(f.store.count(), 0);
    }

    #[test]
    fn direct_challenge_bad_identity_never_reaches_policy_or_commit() {
        let mut f = Fixture::ed();
        f.response.signature.bytes[0] ^= 1;
        assert!(matches!(
            verify_and_issue(&f.response, &f.bind, &context(b"N1"), &f.store, |_| panic!(
                "invalid identity reached policy"
            )),
            Err(Error::Identity(AuthError::BadSignature))
        ));
        f.assert_unused();
    }

    #[test]
    fn direct_challenge_canonical_bind_vector() {
        let key = ClassicalPublicKey {
            alg: ClassicalAlg::Ed25519,
            bytes: vec![0x11; 32],
        };
        let bytes = bind_signing_bytes(
            b"challenge",
            &key,
            &CanonicalTuple::new(["vms", "stop"]).unwrap(),
            &CanonicalTuple::new(["vm", "A"]).unwrap(),
            &[0x22; 32],
        );
        assert_eq!(
            hex::encode(bytes),
            concat!(
                "87746964656e74696b65792d6d6a6f6c6e69722f76316462696e64496368616c6c656e6765",
                "a263616c676765643235353139636b65795820",
                "1111111111111111111111111111111111111111111111111111111111111111",
                "8263766d736473746f708262766d61415820",
                "2222222222222222222222222222222222222222222222222222222222222222"
            )
        );
        assert!(CanonicalTuple::new(["vms: stop"]).is_err());
        assert!(CanonicalTuple::new([""]).is_err());
    }
}
