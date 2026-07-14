//! Prekey bundles for asynchronous session setup (see `docs/CRYPTO_MATH.md`
//! §2.2). A user publishes a [`PrekeyBundle`] so others can start a session
//! while they are offline; the secret half lives in [`PrekeySecrets`].
//!
//! **Phase 1 scope:** the bundle is not yet signed by the ML-DSA-65 identity
//! key (the `sig` field of §2.2). Until that lands, the recipient's identity
//! in a handshake is trust-on-first-use — authenticity (G8) is the next
//! increment. The confidentiality machinery (PQXDH + Double Ratchet) is
//! complete and post-quantum.

use aegis_crypto::ml_kem;
use aegis_crypto::x25519::SecretKey;

/// A user's public prekey bundle.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct PrekeyBundle {
    /// Long-term identity DH public key `IK`.
    pub identity_dh: [u8; 32],
    /// Medium-term signed prekey `SPK`. Doubles as the responder's initial
    /// Double Ratchet public key.
    pub signed_prekey: [u8; 32],
    /// Post-quantum prekey `PQSPK`: an ML-KEM-768 encapsulation key (1184 B).
    pub pq_prekey: Vec<u8>,
    /// Optional one-time prekey `OPK`, consumed by a single handshake.
    pub one_time_prekey: Option<[u8; 32]>,
}

/// The secret half of a [`PrekeyBundle`], held only by its owner.
pub struct PrekeySecrets {
    pub(crate) identity_dh: SecretKey,
    pub(crate) signed_prekey: SecretKey,
    pub(crate) pq_prekey: ml_kem::KeyPair,
    pub(crate) one_time_prekey: Option<SecretKey>,
    identity_dh_public: [u8; 32],
    signed_prekey_public: [u8; 32],
    one_time_prekey_public: Option<[u8; 32]>,
}

impl PrekeySecrets {
    /// Generate a fresh set of prekeys (with one one-time prekey) from OS
    /// randomness.
    pub fn generate() -> Self {
        let mut ik = [0u8; 32];
        let mut spk = [0u8; 32];
        let mut opk = [0u8; 32];
        aegis_crypto::fill_random(&mut ik);
        aegis_crypto::fill_random(&mut spk);
        aegis_crypto::fill_random(&mut opk);
        Self::build(ik, spk, ml_kem::KeyPair::generate(), Some(opk))
    }

    /// Deterministic construction from seeds — for reproducible tests and for
    /// restoring prekeys from stored material. `kem_d`/`kem_z` are the ML-KEM
    /// KeyGen seeds (FIPS 203 `d`, `z`).
    pub fn from_seeds(
        identity_dh: [u8; 32],
        signed_prekey: [u8; 32],
        kem_d: [u8; 32],
        kem_z: [u8; 32],
        one_time_prekey: Option<[u8; 32]>,
    ) -> Self {
        Self::build(
            identity_dh,
            signed_prekey,
            ml_kem::keygen_internal(&kem_d, &kem_z),
            one_time_prekey,
        )
    }

    fn build(
        identity_dh: [u8; 32],
        signed_prekey: [u8; 32],
        pq_prekey: ml_kem::KeyPair,
        one_time_prekey: Option<[u8; 32]>,
    ) -> Self {
        let identity_dh = SecretKey::from_bytes(identity_dh);
        let signed_prekey = SecretKey::from_bytes(signed_prekey);
        let identity_dh_public = identity_dh.public_key();
        let signed_prekey_public = signed_prekey.public_key();
        let (one_time_prekey, one_time_prekey_public) = match one_time_prekey {
            Some(bytes) => {
                let key = SecretKey::from_bytes(bytes);
                let public = key.public_key();
                (Some(key), Some(public))
            }
            None => (None, None),
        };
        PrekeySecrets {
            identity_dh,
            signed_prekey,
            pq_prekey,
            one_time_prekey,
            identity_dh_public,
            signed_prekey_public,
            one_time_prekey_public,
        }
    }

    /// The publishable public bundle.
    pub fn public_bundle(&self) -> PrekeyBundle {
        PrekeyBundle {
            identity_dh: self.identity_dh_public,
            signed_prekey: self.signed_prekey_public,
            pq_prekey: self.pq_prekey.ek.clone(),
            one_time_prekey: self.one_time_prekey_public,
        }
    }

    /// The identity DH public key `IK`.
    pub fn identity_dh_public(&self) -> [u8; 32] {
        self.identity_dh_public
    }

    /// The signed prekey public `SPK`.
    pub fn signed_prekey_public(&self) -> [u8; 32] {
        self.signed_prekey_public
    }

    /// Consume the secrets, yielding the signed-prekey key for use as the
    /// responder's initial ratchet key (moves it out without ever exposing
    /// its bytes).
    pub(crate) fn into_signed_prekey(self) -> SecretKey {
        self.signed_prekey
    }
}
