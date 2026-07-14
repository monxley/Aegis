//! Prekey bundles for asynchronous session setup (see `docs/CRYPTO_MATH.md`
//! §2.2). A user publishes a [`PrekeyBundle`] so others can start a session
//! while they are offline; the secret half lives in [`PrekeySecrets`].
//!
//! The bundle is **signed with an ML-DSA-65 identity key** so a recipient can
//! verify it was authored by the holder of that signing key (authenticity,
//! G8). Binding that signing key to a *specific* identity is done one level up,
//! by checking it against an `AegisId`'s committed hash (`aegis-identity`).
//!
//! Note: this crate keeps the party's identity DH and signing keys inside
//! `PrekeySecrets` so it is self-contained and independently testable. A later
//! phase wires these to a single [`aegis_identity::Identity`] so the same
//! identity keys back both the Aegis ID and the bundle.

use aegis_crypto::x25519::SecretKey;
use aegis_crypto::{ml_dsa, ml_kem, sha256};

const BUNDLE_DOMAIN: &[u8] = b"aegis/prekey-bundle/v1";

/// A user's public prekey bundle.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct PrekeyBundle {
    /// Long-term identity DH public key `IK`.
    pub identity_dh: [u8; 32],
    /// Medium-term signed prekey `SPK`. Doubles as the responder's initial
    /// Double Ratchet public key.
    pub signed_prekey: [u8; 32],
    /// Post-quantum prekey `PQSPK`: an ML-KEM-768 encapsulation key (1184 B),
    /// used by the PQXDH handshake.
    pub pq_prekey: Vec<u8>,
    /// The responder's initial ratchet ML-KEM encapsulation key (1184 B), used
    /// to seed the ongoing post-quantum ratchet (§4) from the very first
    /// message. Distinct from `pq_prekey` so the two are never key-reused.
    pub ratchet_kem_prekey: Vec<u8>,
    /// Optional one-time prekey `OPK`, consumed by a single handshake.
    pub one_time_prekey: Option<[u8; 32]>,
    /// The ML-DSA-65 identity signing public key `IK^sig` (1952 B).
    pub identity_signing_public: Vec<u8>,
    /// ML-DSA-65 signature by `identity_signing_public` over the fields above.
    pub signature: Vec<u8>,
}

impl PrekeyBundle {
    /// Verify the bundle's own signature: it proves the bundle was authored by
    /// the holder of `identity_signing_public` and not since altered. To learn
    /// *whose* key that is, check it against an `AegisId` commitment.
    pub fn verify(&self) -> bool {
        let input = signing_input(
            &self.identity_dh,
            &self.signed_prekey,
            &self.pq_prekey,
            &self.ratchet_kem_prekey,
            &self.one_time_prekey,
        );
        ml_dsa::verify(&self.identity_signing_public, &input, &self.signature)
    }

    /// `SHA-256(identity_signing_public)` — the value an [`AegisId`] commits
    /// to, for binding this bundle to a known identity.
    pub fn signing_key_hash(&self) -> [u8; 32] {
        sha256(&self.identity_signing_public)
    }
}

/// The canonical byte string signed over / verified for a bundle.
fn signing_input(
    identity_dh: &[u8; 32],
    signed_prekey: &[u8; 32],
    pq_prekey: &[u8],
    ratchet_kem_prekey: &[u8],
    one_time_prekey: &Option<[u8; 32]>,
) -> Vec<u8> {
    let mut input = Vec::with_capacity(
        BUNDLE_DOMAIN.len() + 32 + 32 + pq_prekey.len() + ratchet_kem_prekey.len() + 33,
    );
    input.extend_from_slice(BUNDLE_DOMAIN);
    input.extend_from_slice(identity_dh);
    input.extend_from_slice(signed_prekey);
    input.extend_from_slice(pq_prekey);
    input.extend_from_slice(ratchet_kem_prekey);
    match one_time_prekey {
        Some(opk) => {
            input.push(1);
            input.extend_from_slice(opk);
        }
        None => input.push(0),
    }
    input
}

/// The secret half of a [`PrekeyBundle`], held only by its owner. Also holds
/// the party's identity DH and ML-DSA signing keys (see the module note).
pub struct PrekeySecrets {
    pub(crate) identity_dh: SecretKey,
    pub(crate) signed_prekey: SecretKey,
    pub(crate) pq_prekey: ml_kem::KeyPair,
    pub(crate) ratchet_kem: ml_kem::KeyPair,
    pub(crate) one_time_prekey: Option<SecretKey>,
    signing_public: Vec<u8>,
    signing_secret: Vec<u8>,
    identity_dh_public: [u8; 32],
    signed_prekey_public: [u8; 32],
    one_time_prekey_public: Option<[u8; 32]>,
}

impl PrekeySecrets {
    /// Generate a fresh set of prekeys (with one one-time prekey) and a fresh
    /// signing key from OS randomness.
    pub fn generate() -> Self {
        let mut ik = [0u8; 32];
        let mut spk = [0u8; 32];
        let mut opk = [0u8; 32];
        let mut sig = [0u8; 32];
        aegis_crypto::fill_random(&mut ik);
        aegis_crypto::fill_random(&mut spk);
        aegis_crypto::fill_random(&mut opk);
        aegis_crypto::fill_random(&mut sig);
        Self::build(
            ik,
            spk,
            ml_kem::KeyPair::generate(),
            ml_kem::KeyPair::generate(),
            Some(opk),
            sig,
        )
    }

    /// Deterministic construction from seeds — for reproducible tests and for
    /// restoring prekeys from stored material. `kem_d`/`kem_z` are the ML-KEM
    /// KeyGen seeds (FIPS 203 `d`, `z`) for the PQXDH prekey; `ratchet_kem_seed`
    /// seeds the ratchet KEM prekey; `signing_seed` is the ML-DSA-65 seed.
    pub fn from_seeds(
        identity_dh: [u8; 32],
        signed_prekey: [u8; 32],
        kem_d: [u8; 32],
        kem_z: [u8; 32],
        one_time_prekey: Option<[u8; 32]>,
        signing_seed: [u8; 32],
        ratchet_kem_seed: [u8; 32],
    ) -> Self {
        // Derive the ratchet KEM's (d, z) deterministically from one seed.
        let ratchet_kem = ml_kem::keygen_internal(&ratchet_kem_seed, &sha256(&ratchet_kem_seed));
        Self::build(
            identity_dh,
            signed_prekey,
            ml_kem::keygen_internal(&kem_d, &kem_z),
            ratchet_kem,
            one_time_prekey,
            signing_seed,
        )
    }

    fn build(
        identity_dh: [u8; 32],
        signed_prekey: [u8; 32],
        pq_prekey: ml_kem::KeyPair,
        ratchet_kem: ml_kem::KeyPair,
        one_time_prekey: Option<[u8; 32]>,
        signing_seed: [u8; 32],
    ) -> Self {
        let identity_dh = SecretKey::from_bytes(identity_dh);
        let signed_prekey = SecretKey::from_bytes(signed_prekey);
        let identity_dh_public = identity_dh.public_key();
        let signed_prekey_public = signed_prekey.public_key();
        let (signing_public, signing_secret) = ml_dsa::keypair_from_seed(&signing_seed);
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
            ratchet_kem,
            one_time_prekey,
            signing_public,
            signing_secret,
            identity_dh_public,
            signed_prekey_public,
            one_time_prekey_public,
        }
    }

    /// The publishable public bundle, signed with the identity signing key.
    pub fn public_bundle(&self) -> PrekeyBundle {
        let pq_prekey = self.pq_prekey.ek.clone();
        let ratchet_kem_prekey = self.ratchet_kem.ek.clone();
        let input = signing_input(
            &self.identity_dh_public,
            &self.signed_prekey_public,
            &pq_prekey,
            &ratchet_kem_prekey,
            &self.one_time_prekey_public,
        );
        let signature = ml_dsa::sign(&self.signing_secret, &input);
        PrekeyBundle {
            identity_dh: self.identity_dh_public,
            signed_prekey: self.signed_prekey_public,
            pq_prekey,
            ratchet_kem_prekey,
            one_time_prekey: self.one_time_prekey_public,
            identity_signing_public: self.signing_public.clone(),
            signature,
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

    /// The identity signing public key `IK^sig`.
    pub fn signing_public(&self) -> &[u8] {
        &self.signing_public
    }

    /// Consume the secrets, yielding the responder's initial ratchet material:
    /// the signed-prekey key (its X25519 ratchet key) and the ratchet KEM
    /// keypair (its post-quantum ratchet key). Moves them out without ever
    /// exposing secret bytes.
    pub(crate) fn into_responder_ratchet_keys(self) -> (SecretKey, ml_kem::KeyPair) {
        (self.signed_prekey, self.ratchet_kem)
    }
}
