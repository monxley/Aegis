//! Stealth addressing — recipient anonymity (see `docs/CRYPTO_MATH.md` §1).
//!
//! Every message to a recipient produces a *fresh* one-time address on the
//! relay, so the relay cannot link two messages as going to the same person,
//! yet the recipient can efficiently detect messages meant for them using
//! only their view key.
//!
//! Construction (DH-only, needs only X25519 — no Ed25519 point arithmetic):
//!
//! ```text
//! sender:     r  ← random ;  R = r·G ;  S = r·V
//! recipient:  S' = v·R = r·V = S      (commutativity)
//! both:       σ  = HKDF(salt=∅, ikm=S, info="aegis/addr/v1" ‖ R ‖ V, 17)
//!             addr_tag = σ[0..16]  (relay storage key)
//!             view_tag = σ[16]     (1-byte fast-reject during scanning)
//! ```

use aegis_crypto::{fill_random, hkdf_expand, hkdf_extract, x25519::SecretKey};

/// Length of the one-time relay address tag, in bytes.
pub const ADDR_TAG_LEN: usize = 16;

/// HKDF output: 16-byte address tag + 1-byte view tag.
const DERIVE_LEN: usize = ADDR_TAG_LEN + 1;
const ADDR_INFO_PREFIX: &[u8] = b"aegis/addr/v1";
const ENVELOPE_INFO_PREFIX: &[u8] = b"aegis/envelope/v1";

/// A recipient's published view public key `V = v·G`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct ViewPublicKey(pub [u8; 32]);

/// The sender's per-message ephemeral public key `R = r·G`, published with
/// the message so the recipient can recompute the shared secret.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct EphemeralPublic(pub [u8; 32]);

/// A one-time stealth address: what the relay sees as a message's key.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct StealthAddress {
    /// 16-byte relay storage key. Unlinkable across messages under DDH.
    pub addr_tag: [u8; ADDR_TAG_LEN],
    /// 1-byte fast-reject tag checked before the full 16-byte compare.
    pub view_tag: u8,
}

/// Errors from stealth-address derivation.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum StealthError {
    /// The X25519 shared secret was the all-zero point, which happens for
    /// small-order inputs. Rejected per RFC 7748 §6.1. Honest keys (clamped)
    /// never trigger this; a peer supplying such a point is misbehaving.
    DegenerateSharedSecret,
}

impl core::fmt::Display for StealthError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            StealthError::DegenerateSharedSecret => {
                write!(f, "degenerate (all-zero) X25519 shared secret")
            }
        }
    }
}

impl std::error::Error for StealthError {}

/// Reject the all-zero shared secret (RFC 7748 §6.1 contributory check).
pub(crate) fn checked_shared(secret: [u8; 32]) -> Result<[u8; 32], StealthError> {
    if secret == [0u8; 32] {
        Err(StealthError::DegenerateSharedSecret)
    } else {
        Ok(secret)
    }
}

/// σ = HKDF(∅, shared, "aegis/addr/v1" ‖ R ‖ V, 17) → (addr_tag, view_tag).
pub(crate) fn tags_from_shared(
    shared: &[u8; 32],
    ephemeral: &[u8; 32],
    view_public: &[u8; 32],
) -> StealthAddress {
    let prk = hkdf_extract(&[], shared);
    let mut info = Vec::with_capacity(ADDR_INFO_PREFIX.len() + 64);
    info.extend_from_slice(ADDR_INFO_PREFIX);
    info.extend_from_slice(ephemeral);
    info.extend_from_slice(view_public);
    let mut out = [0u8; DERIVE_LEN];
    hkdf_expand(&prk, &info, &mut out);

    let mut addr_tag = [0u8; ADDR_TAG_LEN];
    addr_tag.copy_from_slice(&out[..ADDR_TAG_LEN]);
    StealthAddress {
        addr_tag,
        view_tag: out[ADDR_TAG_LEN],
    }
}

/// Sender side: derive a fresh one-time address for `recipient`, drawing a
/// random ephemeral scalar from the OS CSPRNG. Returns the address (to store
/// the message under on the relay) and the ephemeral public `R` (to publish
/// alongside it).
pub fn create(
    recipient: &ViewPublicKey,
) -> Result<(StealthAddress, EphemeralPublic), StealthError> {
    let mut r = [0u8; 32];
    fill_random(&mut r);
    create_with_ephemeral(recipient, r)
}

/// Sender side with a caller-supplied ephemeral scalar. Exposed for
/// deterministic testing and for callers that must reuse `r` to derive the
/// message-encryption key in later phases. The scalar is X25519-clamped
/// internally, so any 32 bytes are acceptable.
pub fn create_with_ephemeral(
    recipient: &ViewPublicKey,
    ephemeral_scalar: [u8; 32],
) -> Result<(StealthAddress, EphemeralPublic), StealthError> {
    let r = SecretKey::from_bytes(ephemeral_scalar);
    let big_r = r.public_key();
    let shared = checked_shared(r.diffie_hellman(&recipient.0))?;
    let address = tags_from_shared(&shared, &big_r, &recipient.0);
    Ok((address, EphemeralPublic(big_r)))
}

/// A per-message envelope key `K_env = HKDF(S, "aegis/envelope/v1" ‖ R ‖ V, 32)`,
/// derived from the same stealth shared secret `S` as the address (a different
/// `info`, so it is an independent key). A recipient who matches the address
/// can derive it; the relay cannot. Used to seal the message envelope so even
/// the ratchet header and sender identity are hidden from the relay.
pub(crate) fn envelope_key_from_shared(
    shared: &[u8; 32],
    ephemeral: &[u8; 32],
    view_public: &[u8; 32],
) -> [u8; 32] {
    let prk = hkdf_extract(&[], shared);
    let mut info = Vec::with_capacity(ENVELOPE_INFO_PREFIX.len() + 64);
    info.extend_from_slice(ENVELOPE_INFO_PREFIX);
    info.extend_from_slice(ephemeral);
    info.extend_from_slice(view_public);
    let mut key = [0u8; 32];
    hkdf_expand(&prk, &info, &mut key);
    key
}

/// A sealed-envelope addressing result: the one-time [`StealthAddress`], the
/// ephemeral public `R` to publish, and the per-message envelope key with which
/// to seal the payload for the recipient.
#[derive(Clone)]
pub struct SealedStealth {
    /// One-time relay address.
    pub address: StealthAddress,
    /// Ephemeral public `R`, published with the message.
    pub ephemeral: EphemeralPublic,
    /// Per-message key to AEAD-seal the envelope payload.
    pub envelope_key: [u8; 32],
}

/// Sender side: like [`create`], but also derives the per-message envelope key
/// so the caller can seal the payload (sender identity, ratchet header, …) for
/// the recipient's eyes only. Draws a random ephemeral from the OS CSPRNG.
pub fn create_sealed(recipient: &ViewPublicKey) -> Result<SealedStealth, StealthError> {
    let mut r = [0u8; 32];
    fill_random(&mut r);
    create_sealed_with_ephemeral(recipient, r)
}

/// [`create_sealed`] with a caller-supplied ephemeral scalar (deterministic
/// testing; clamped internally).
pub fn create_sealed_with_ephemeral(
    recipient: &ViewPublicKey,
    ephemeral_scalar: [u8; 32],
) -> Result<SealedStealth, StealthError> {
    let r = SecretKey::from_bytes(ephemeral_scalar);
    let big_r = r.public_key();
    let shared = checked_shared(r.diffie_hellman(&recipient.0))?;
    let address = tags_from_shared(&shared, &big_r, &recipient.0);
    let envelope_key = envelope_key_from_shared(&shared, &big_r, &recipient.0);
    Ok(SealedStealth {
        address,
        ephemeral: EphemeralPublic(big_r),
        envelope_key,
    })
}
