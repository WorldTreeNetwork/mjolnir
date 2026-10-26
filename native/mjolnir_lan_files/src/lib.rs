//! Guest authorization boundary. No owner secret or recryption key enters this process.
use bc_envelope::prelude::*;
use std::{path::Path, sync::Mutex, time::{SystemTime, UNIX_EPOCH}};
use identikey_auth::{ClassicalAlg, ChallengeIssuer, InMemoryNonceStore, NonceStore, Response, Verified, VerifyPolicy, verify_response};
use recrypt_core::sign::{VerifyingKeys, VerifyPolicy as CapPolicy};
use recrypt_storage_auth::{Capability, Permission, PublicKeyFingerprint, SubjectKind};
use rusqlite::{params, Connection, OptionalExtension};

pub const AUD: &str = "mjolnir:lan-files:v1";
pub const BLOB_DOOR_URL: &str = "http://10.200.0.1:7222";
pub const REVISIONS: (&str, &str) = (env!("IDENTIKEY_AUTH_REV"), env!("RECRYPT_STORAGE_AUTH_REV"));
pub type Result<T> = std::result::Result<T, Error>;
#[derive(Debug)]
pub enum Error { Auth, Hash, Owner, Door, Metadata }

pub fn now() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() }
pub fn fingerprint(key: &[u8;32]) -> PublicKeyFingerprint { PublicKeyFingerprint::from_public_key(key) }
fn raw_key(v: Verified) -> Result<[u8;32]> {
    if v.public_key.alg != ClassicalAlg::Ed25519 { return Err(Error::Auth); }
    v.public_key.bytes.try_into().map_err(|_| Error::Auth)
}

pub struct Share {
    nonces: Mutex<InMemoryNonceStore>,
    db: Mutex<Connection>,
}
impl Share {
    /// This path MUST be on the persistent guest subvolume, never /run.
    pub fn open(path: &Path) -> Result<Self> {
        let db = Connection::open(path).map_err(|_| Error::Metadata)?;
        db.busy_timeout(std::time::Duration::from_secs(10)).map_err(|_| Error::Metadata)?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS owners (hash BLOB PRIMARY KEY CHECK(length(hash)=32),
              owner_key BLOB NOT NULL CHECK(length(owner_key)=32));
            CREATE TABLE IF NOT EXISTS caps (envelope BLOB PRIMARY KEY);")
            .map_err(|_| Error::Metadata)?;
        Ok(Self { nonces: Mutex::new(InMemoryNonceStore::new()), db: Mutex::new(db) })
    }
    pub fn challenge(&self) -> Vec<u8> {
        let mut nonces = self.nonces.lock().unwrap();
        nonces.gc(now());
        ChallengeIssuer::new(AUD, 60).issue(&mut *nonces, now()).to_bytes()
    }
    fn authenticate(&self, proof: &[u8]) -> Result<[u8;32]> {
        let response = Response::from_bytes(proof).map_err(|_| Error::Auth)?;
        let v = verify_response(&response, AUD, now(), 0, VerifyPolicy::PqOptional,
            &mut *self.nonces.lock().unwrap()).map_err(|_| Error::Auth)?;
        raw_key(v)
    }
    pub fn owner(&self, hash: &[u8;32]) -> Result<Option<[u8;32]>> {
        let bytes: Option<Vec<u8>> = self.db.lock().unwrap().query_row(
            "SELECT owner_key FROM owners WHERE hash=?1", params![hash.as_slice()], |r| r.get(0)
        ).optional().map_err(|_| Error::Metadata)?;
        bytes.map(|b| b.try_into().map_err(|_| Error::Metadata)).transpose()
    }
    fn register(&self, hash: &[u8;32], key: &[u8;32]) -> Result<()> {
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(|_| Error::Metadata)?;
        tx.execute("INSERT OR IGNORE INTO owners VALUES (?1,?2)", params![hash.as_slice(), key.as_slice()]).map_err(|_| Error::Metadata)?;
        let owner: Vec<u8> = tx.query_row("SELECT owner_key FROM owners WHERE hash=?1", params![hash.as_slice()], |r|r.get(0)).map_err(|_| Error::Metadata)?;
        if owner.as_slice() != key.as_slice() { return Err(Error::Owner); }
        tx.commit().map_err(|_| Error::Metadata)
    }
    /// The door closure is invoked only after authentication/hash verification.
    /// Success is required; timeouts/lost responses must return Err(Door).
    pub async fn put<F, Fut>(&self, hash: [u8;32], proof: &[u8], body: &[u8], door: F) -> Result<()>
    where F: FnOnce() -> Fut, Fut: std::future::Future<Output=Result<()>> {
        let key = self.authenticate(proof)?;
        if blake3::hash(body).as_bytes() != &hash { return Err(Error::Hash); }
        door().await?;
        self.register(&hash, &key)
    }
    pub fn authorize_get(&self, hash: [u8;32], proof: &[u8], envelope: &[u8]) -> Result<()> {
        let holder = self.authenticate(proof)?;
        let owner = self.owner(&hash)?.ok_or(Error::Owner)?;
        let keys = VerifyingKeys {
            ed25519: ed25519_dalek::VerifyingKey::from_bytes(&owner).map_err(|_| Error::Auth)?,
            ml_dsa: None,
        };
        let cap = Capability::verify_full(envelope, &keys, CapPolicy::PqOptional, Permission::Read).map_err(|_| Error::Auth)?;
        // Upstream parsing treats some malformed optional fields as absent.
        // Reject parent assertions by presence, including malformed/elided values.
        let inner = Envelope::try_from_cbor_data(envelope.to_vec())
            .map_err(|_| Error::Auth)?
            .try_unwrap().map_err(|_| Error::Auth)?;
        if !inner.assertions_with_predicate("parent").is_empty() {
            return Err(Error::Auth);
        }

        if cap.parent.is_some() || cap.subject_kind != SubjectKind::File || cap.subject != hash
            || cap.granted_to != fingerprint(&holder) || cap.issuer != fingerprint(&owner)
            || cap.expires_at.is_some_and(|expiry| expiry <= now()) {
            return Err(Error::Auth);
        }
        self.db.lock().unwrap().execute("INSERT OR IGNORE INTO caps VALUES (?1)", params![envelope]).map_err(|_| Error::Metadata)?;
        Ok(())
    }
}

pub mod http;

#[cfg(test)]
mod tests {
    use super::*;
    use identikey_auth::{Challenge, Signer, SoftwareSigner};
    use recrypt_core::sign::SigningKeys;
    const BODY: &[u8] = b"encrypted bytes";
    fn hash() -> [u8;32] { *blake3::hash(BODY).as_bytes() }
    fn key(seed: u8) -> [u8;32] { ed25519_dalek::SigningKey::from_bytes(&[seed;32]).verifying_key().to_bytes() }
    fn proof(share: &Share, seed: u8) -> Vec<u8> {
        let c = Challenge::from_bytes(&share.challenge()).unwrap();
        SoftwareSigner::from_ed25519_seed([seed;32]).respond(&c).unwrap().to_bytes()
    }
    fn cap() -> Capability {
        Capability::new(hash(), SubjectKind::File, fingerprint(&key(2)), fingerprint(&key(1)),
            [Permission::Read].into_iter().collect(), Some(now()+3600))
    }
    fn signed(c: &Capability, seed: u8) -> Vec<u8> {
        c.sign(&SigningKeys { ed25519: ed25519_dalek::SigningKey::from_bytes(&[seed;32]), ml_dsa: None }).unwrap()
    }
    fn setup() -> (tempfile::TempDir, Share) {
        let dir = tempfile::tempdir().unwrap();
        let share = Share::open(&dir.path().join("owners.sqlite")).unwrap();
        (dir, share)
    }
    async fn put(share: &Share, seed: u8) -> Result<()> {
        share.put(hash(), &proof(share, seed), BODY, || async { Ok(()) }).await
    }

    #[tokio::test]
    async fn get_predicate_and_durable_owner_key_after_restart() {
        let (dir, share) = setup();
        put(&share, 1).await.unwrap();
        let envelope = signed(&cap(), 1);
        let p = proof(&share, 2);
        share.authorize_get(hash(), &p, &envelope).unwrap();
        assert!(share.authorize_get(hash(), &p, &envelope).is_err());
        drop(share);
        let share = Share::open(&dir.path().join("owners.sqlite")).unwrap();
        // Only the holder reconnects; issuer lookup comes entirely from disk.
        share.authorize_get(hash(), &proof(&share, 2), &envelope).unwrap();
        assert_eq!(share.owner(&hash()).unwrap(), Some(key(1)));
        for mutate in 0..7 {
            let mut c = cap();
            match mutate {
                0 => c.subject = [0;32],
                1 => c.subject_kind = SubjectKind::Keyspace,
                2 => c.granted_to = fingerprint(&key(3)),
                3 => c.issuer = fingerprint(&key(3)),
                4 => c.expires_at = Some(now()-1),
                5 => c.permissions.clear(),
                _ => c.parent = Some([0;32]),
            }
            assert!(share.authorize_get(hash(), &proof(&share, 2), &signed(&c,1)).is_err(), "negative {mutate}");
        }
        // Forged signature, self-issued cap and missing cap all fail.
        assert!(share.authorize_get(hash(), &proof(&share,2), &signed(&cap(),3)).is_err());
        let mut self_cap = cap(); self_cap.issuer = fingerprint(&key(2));
        assert!(share.authorize_get(hash(), &proof(&share,2), &signed(&self_cap,2)).is_err());
        assert!(share.authorize_get(hash(), &proof(&share,2), &[]).is_err());
        assert!(share.authorize_get(hash(), &proof(&share,3), &envelope).is_err());
        assert!(share.authorize_get([1;32], &proof(&share,2), &envelope).is_err());
    }

    #[tokio::test]
    async fn auth_wrong_audience_replay_and_tampered_signature() {
        let (_dir, share) = setup();
        let p = proof(&share, 1);
        share.put(hash(), &p, BODY, || async { Ok(()) }).await.unwrap();
        assert!(share.put(hash(), &p, BODY, || async { panic!("replay reached door") }).await.is_err());
        let mut challenge = Challenge::from_bytes(&share.challenge()).unwrap();
        challenge.audience = "other-service".into();
        let p = SoftwareSigner::from_ed25519_seed([1;32]).respond(&challenge).unwrap().to_bytes();
        assert!(share.put(hash(), &p, BODY, || async { panic!("aud reached door") }).await.is_err());
        let mut r = Response::from_bytes(&proof(&share, 1)).unwrap();
        r.signature.bytes[0] ^= 1;
        assert!(share.put(hash(), &r.to_bytes(), BODY, || async { panic!("forgery reached door") }).await.is_err());
        let mut challenge = Challenge::from_bytes(&share.challenge()).unwrap();
        challenge.issued_at = now()-120; challenge.expires_at = now()-60;
        let p = SoftwareSigner::from_ed25519_seed([1;32]).respond(&challenge).unwrap().to_bytes();
        assert!(share.authenticate(&p).is_err());
    }

    #[tokio::test]
    async fn put_requires_door_success_and_hash_before_ownership() {
        let (_dir, share) = setup();
        assert!(share.put(hash(), &proof(&share, 1), b"bad", || async { panic!("hash reached door") }).await.is_err());
        assert_eq!(share.owner(&hash()).unwrap(), None);
        assert!(share.put(hash(), &proof(&share, 1), BODY, || async {
            assert_eq!(share.owner(&hash()).unwrap(), None);
            Err(Error::Door) // includes timeout or lost success response
        }).await.is_err());
        assert_eq!(share.owner(&hash()).unwrap(), None);
        put(&share,1).await.unwrap();
        put(&share,1).await.unwrap();
        assert!(matches!(put(&share,2).await, Err(Error::Owner)));
        assert_eq!(share.owner(&hash()).unwrap(), Some(key(1)));
    }

    #[tokio::test]
    async fn orphan_is_not_an_owner_and_metadata_failure_is_failed_put() {
        let (dir, share) = setup();
        // Crash after door success, before registration: no metadata was committed.
        let share = std::sync::Arc::new(share);
        let crash_share = share.clone();
        assert!(tokio::spawn(async move {
            crash_share.put(hash(), &proof(&crash_share,1), BODY, || async {
                panic!("door accepted, process crashed");
                #[allow(unreachable_code)] Ok(())
            }).await
        }).await.is_err());
        drop(share);
        let share = Share::open(&dir.path().join("owners.sqlite")).unwrap();
        assert_eq!(share.owner(&hash()).unwrap(), None);
        assert!(share.authorize_get(hash(), &proof(&share,2), &signed(&cap(),1)).is_err());
        share.db.lock().unwrap().execute_batch("CREATE TRIGGER fail_write BEFORE INSERT ON owners BEGIN SELECT RAISE(ABORT, 'disk failure'); END;").unwrap();
        let reached = std::sync::atomic::AtomicBool::new(false);
        assert!(matches!(share.put(hash(), &proof(&share,1), BODY, || async {
            reached.store(true,std::sync::atomic::Ordering::SeqCst); Ok(())
        }).await, Err(Error::Metadata)));
        assert!(reached.load(std::sync::atomic::Ordering::SeqCst));
        assert_eq!(share.owner(&hash()).unwrap(), None);
        share.db.lock().unwrap().execute_batch("DROP TRIGGER fail_write").unwrap();
        put(&share,2).await.unwrap(); // must perform a new successful door PUT
        assert_eq!(share.owner(&hash()).unwrap(), Some(key(2)));
    }

    #[tokio::test(flavor="multi_thread", worker_threads=2)]
    async fn concurrent_different_owners_cannot_replace_winner() {
        let (dir, share) = setup();
        let other = Share::open(&dir.path().join("owners.sqlite")).unwrap();
        let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
        let race = |s: Share, seed, barrier: std::sync::Arc<tokio::sync::Barrier>| tokio::spawn(async move {
            s.put(hash(), &proof(&s,seed), BODY, || async { barrier.wait().await; Ok(()) }).await
        });
        let a = race(share,1,barrier.clone()); let b = race(other,2,barrier);
        let a = a.await.unwrap(); let b = b.await.unwrap();
        assert_ne!(a.is_ok(),b.is_ok());
        let reopened = Share::open(&dir.path().join("owners.sqlite")).unwrap();
        assert_eq!(reopened.owner(&hash()).unwrap(), Some(key(if a.is_ok() {1} else {2})));
    }
}
