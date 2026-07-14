//! # aegis-session — Phases 1–1.6
//!
//! Session setup and message encryption for Aegis: the machinery that makes a
//! message unreadable even if intercepted, now *and* against a future quantum
//! adversary. Implements Layers 2–3 of the protocol
//! ([`AEGIS_PROTOCOL.md`](../../../AEGIS_PROTOCOL.md)), with the exact math in
//! [`docs/CRYPTO_MATH.md`](../../../docs/CRYPTO_MATH.md) §2–§4:
//!
//! - [`pqxdh`] — asynchronous post-quantum handshake (four X25519 DHs mixed
//!   with an ML-KEM-768 encapsulation) yielding a shared root secret;
//! - [`ratchet`] — the Double Ratchet with an ongoing post-quantum ratchet:
//!   a fresh key per message (forward secrecy), a DH step that self-heals after
//!   compromise, and an ML-KEM re-encapsulation mixed into the root at every
//!   step so the whole conversation stays post-quantum confidential;
//! - [`bundle`] — ML-DSA-65-signed prekey bundles (authenticity, G8).
//!
//! Zero third-party dependencies — all primitives come from [`aegis_crypto`].
//!
//! ```
//! use aegis_session::{establish_initiator, establish_responder, PrekeySecrets};
//! use aegis_crypto::x25519::SecretKey;
//!
//! // Bob publishes a prekey bundle; Alice starts a session against it.
//! let bob = PrekeySecrets::generate();
//! let alice_identity = SecretKey::from_bytes([7u8; 32]);
//! let (initial, mut alice) = establish_initiator(&alice_identity, &bob.public_bundle()).unwrap();
//!
//! // Bob recovers the same session from Alice's initial message.
//! let mut bob = establish_responder(bob, &initial).unwrap();
//!
//! // They now exchange end-to-end encrypted, forward-secret messages.
//! let msg = alice.encrypt(b"hello bob", b"").unwrap();
//! assert_eq!(bob.decrypt(&msg, b"").unwrap(), b"hello bob");
//! let reply = bob.encrypt(b"hi alice", b"").unwrap();
//! assert_eq!(alice.decrypt(&reply, b"").unwrap(), b"hi alice");
//! ```

pub mod bundle;
pub mod pqxdh;
pub mod ratchet;

pub use bundle::{PrekeyBundle, PrekeySecrets};
pub use pqxdh::InitialMessage;
pub use ratchet::{DoubleRatchet, Message, RatchetError};

use aegis_crypto::x25519::SecretKey;

/// Errors from session setup.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SessionError {
    /// The initial message referenced a one-time prekey the responder no
    /// longer holds (e.g. it was already consumed).
    MissingOneTimePrekey,
    /// The prekey bundle's signature did not verify — it was tampered with, or
    /// not authored by the holder of its signing key. The initiator refuses to
    /// start a session against an unauthenticated bundle.
    UnauthenticBundle,
}

impl core::fmt::Display for SessionError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            SessionError::MissingOneTimePrekey => {
                f.write_str("initial message referenced an unknown one-time prekey")
            }
            SessionError::UnauthenticBundle => {
                f.write_str("prekey bundle signature did not verify")
            }
        }
    }
}

impl std::error::Error for SessionError {}

/// Initiator: verify the bundle's signature, run PQXDH against it, and return
/// the initial message to send plus a ready-to-use ratchet.
/// `initiator_identity_dh` is the initiator's long-term identity DH key.
///
/// Fails with [`SessionError::UnauthenticBundle`] if the bundle signature does
/// not verify. Binding the bundle's signing key to a *known* identity (via an
/// `AegisId` commitment) is the caller's responsibility.
pub fn establish_initiator(
    initiator_identity_dh: &SecretKey,
    bundle: &PrekeyBundle,
) -> Result<(InitialMessage, DoubleRatchet), SessionError> {
    if !bundle.verify() {
        return Err(SessionError::UnauthenticBundle);
    }
    let (sk, message) = pqxdh::initiate(initiator_identity_dh, bundle);
    let ratchet =
        DoubleRatchet::init_initiator(sk, bundle.signed_prekey, &bundle.ratchet_kem_prekey);
    Ok((message, ratchet))
}

/// Responder: run PQXDH from the received `message` and the responder's own
/// prekey secrets, returning a ready-to-use ratchet. Consumes `secrets` so the
/// signed prekey can seed the ratchet without exposing its bytes.
pub fn establish_responder(
    secrets: PrekeySecrets,
    message: &InitialMessage,
) -> Result<DoubleRatchet, SessionError> {
    let sk = pqxdh::respond(&secrets, message)?;
    let (signed_prekey, ratchet_kem) = secrets.into_responder_ratchet_keys();
    Ok(DoubleRatchet::init_responder(
        sk,
        signed_prekey,
        ratchet_kem,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bob_secrets(with_one_time: bool) -> PrekeySecrets {
        PrekeySecrets::from_seeds(
            [1u8; 32],
            [2u8; 32],
            [3u8; 32],
            [4u8; 32],
            with_one_time.then_some([5u8; 32]),
            [6u8; 32],
            [7u8; 32],
        )
    }

    fn alice_identity() -> SecretKey {
        SecretKey::from_bytes([9u8; 32])
    }

    #[test]
    fn pqxdh_parties_agree_with_one_time_prekey() {
        let bob = bob_secrets(true);
        let (sk_a, message) = pqxdh::initiate(&alice_identity(), &bob.public_bundle());
        assert!(message.used_one_time);
        let sk_b = pqxdh::respond(&bob, &message).unwrap();
        assert_eq!(sk_a, sk_b);
    }

    #[test]
    fn pqxdh_parties_agree_without_one_time_prekey() {
        let bob = bob_secrets(false);
        let (sk_a, message) = pqxdh::initiate(&alice_identity(), &bob.public_bundle());
        assert!(!message.used_one_time);
        let sk_b = pqxdh::respond(&bob, &message).unwrap();
        assert_eq!(sk_a, sk_b);
    }

    #[test]
    fn pqxdh_responder_recovery_is_a_pure_function() {
        let bob = bob_secrets(true);
        let (_, message) = pqxdh::initiate(&alice_identity(), &bob.public_bundle());
        assert_eq!(
            pqxdh::respond(&bob, &message).unwrap(),
            pqxdh::respond(&bob, &message).unwrap()
        );
    }

    #[test]
    fn tampered_kem_ciphertext_breaks_agreement() {
        // The post-quantum term binds SK: corrupting CT must change the
        // responder's SK (implicit rejection), so the session fails to match.
        let bob = bob_secrets(true);
        let (sk_a, mut message) = pqxdh::initiate(&alice_identity(), &bob.public_bundle());
        message.kem_ciphertext[0] ^= 1;
        let sk_b = pqxdh::respond(&bob, &message).unwrap();
        assert_ne!(sk_a, sk_b);
    }

    #[test]
    fn tampered_ephemeral_breaks_agreement() {
        let bob = bob_secrets(true);
        let (sk_a, mut message) = pqxdh::initiate(&alice_identity(), &bob.public_bundle());
        message.ephemeral[0] ^= 1;
        let sk_b = pqxdh::respond(&bob, &message).unwrap();
        assert_ne!(sk_a, sk_b);
    }

    #[test]
    fn full_session_round_trip_both_directions() {
        let bob = bob_secrets(true);
        let (initial, mut alice) =
            establish_initiator(&alice_identity(), &bob.public_bundle()).unwrap();
        let mut bob = establish_responder(bob, &initial).unwrap();

        let m1 = alice.encrypt(b"hello bob", b"ad1").unwrap();
        assert_eq!(bob.decrypt(&m1, b"ad1").unwrap(), b"hello bob");

        let r1 = bob.encrypt(b"hi alice", b"ad2").unwrap();
        assert_eq!(alice.decrypt(&r1, b"ad2").unwrap(), b"hi alice");

        // Several more back-and-forth turns exercise repeated DH ratchets.
        for i in 0..5u8 {
            let a = alice.encrypt(&[i; 16], b"").unwrap();
            assert_eq!(bob.decrypt(&a, b"").unwrap(), vec![i; 16]);
            let b = bob.encrypt(&[i ^ 0xff; 16], b"").unwrap();
            assert_eq!(alice.decrypt(&b, b"").unwrap(), vec![i ^ 0xff; 16]);
        }
    }

    #[test]
    fn many_messages_in_one_direction_advance_the_chain() {
        let bob = bob_secrets(true);
        let (initial, mut alice) =
            establish_initiator(&alice_identity(), &bob.public_bundle()).unwrap();
        let mut bob = establish_responder(bob, &initial).unwrap();
        for i in 0..100u32 {
            let m = alice.encrypt(&i.to_le_bytes(), b"").unwrap();
            assert_eq!(bob.decrypt(&m, b"").unwrap(), i.to_le_bytes());
        }
    }

    #[test]
    fn out_of_order_delivery_is_handled() {
        let bob = bob_secrets(true);
        let (initial, mut alice) =
            establish_initiator(&alice_identity(), &bob.public_bundle()).unwrap();
        let mut bob = establish_responder(bob, &initial).unwrap();

        let m0 = alice.encrypt(b"zero", b"").unwrap();
        let m1 = alice.encrypt(b"one", b"").unwrap();
        let m2 = alice.encrypt(b"two", b"").unwrap();
        // Deliver 2, then 0, then 1 — skipped keys must cover the gaps.
        assert_eq!(bob.decrypt(&m2, b"").unwrap(), b"two");
        assert_eq!(bob.decrypt(&m0, b"").unwrap(), b"zero");
        assert_eq!(bob.decrypt(&m1, b"").unwrap(), b"one");
    }

    #[test]
    fn tampered_ciphertext_is_rejected() {
        let bob = bob_secrets(true);
        let (initial, mut alice) =
            establish_initiator(&alice_identity(), &bob.public_bundle()).unwrap();
        let mut bob = establish_responder(bob, &initial).unwrap();
        let mut m = alice.encrypt(b"secret", b"").unwrap();
        m.ciphertext[0] ^= 1;
        assert_eq!(bob.decrypt(&m, b""), Err(RatchetError::DecryptFailed));
    }

    #[test]
    fn wrong_associated_data_is_rejected() {
        let bob = bob_secrets(true);
        let (initial, mut alice) =
            establish_initiator(&alice_identity(), &bob.public_bundle()).unwrap();
        let mut bob = establish_responder(bob, &initial).unwrap();
        let m = alice.encrypt(b"secret", b"context-a").unwrap();
        assert_eq!(
            bob.decrypt(&m, b"context-b"),
            Err(RatchetError::DecryptFailed)
        );
    }

    #[test]
    fn responder_cannot_send_before_receiving() {
        let bob = bob_secrets(true);
        let (initial, _alice) =
            establish_initiator(&alice_identity(), &bob.public_bundle()).unwrap();
        let mut bob = establish_responder(bob, &initial).unwrap();
        assert_eq!(
            bob.encrypt(b"too soon", b""),
            Err(RatchetError::NotInitializedForSending)
        );
    }

    #[test]
    fn signed_bundle_verifies() {
        assert!(bob_secrets(true).public_bundle().verify());
        assert!(bob_secrets(false).public_bundle().verify());
    }

    #[test]
    fn tampered_bundle_fails_verification() {
        let mut bundle = bob_secrets(true).public_bundle();
        bundle.signed_prekey[0] ^= 1; // swap in a different prekey
        assert!(!bundle.verify());
        assert_eq!(
            establish_initiator(&alice_identity(), &bundle).err(),
            Some(SessionError::UnauthenticBundle)
        );
    }

    #[test]
    fn signature_from_a_different_key_fails_verification() {
        // Swap only the advertised signing key for another party's: the
        // existing signature no longer verifies under it. (Binding the key to a
        // specific identity via an AegisId is tested in aegis-identity.)
        let mut bundle = bob_secrets(true).public_bundle();
        let attacker = PrekeySecrets::from_seeds(
            [1u8; 32],
            [2u8; 32],
            [3u8; 32],
            [4u8; 32],
            Some([5u8; 32]),
            [99u8; 32], // different signing seed
            [7u8; 32],
        );
        bundle.identity_signing_public = attacker.signing_public().to_vec();
        assert!(!bundle.verify());
    }

    #[test]
    fn a_different_session_cannot_decrypt() {
        // A ratchet from an unrelated handshake must not open Alice's message.
        let bob = bob_secrets(true);
        let (initial, mut alice) =
            establish_initiator(&alice_identity(), &bob.public_bundle()).unwrap();
        let _bob = establish_responder(bob, &initial).unwrap();

        let other = bob_secrets(true);
        let other_identity = SecretKey::from_bytes([42u8; 32]);
        let (other_initial, _) =
            establish_initiator(&other_identity, &other.public_bundle()).unwrap();
        let mut other_bob = establish_responder(other, &other_initial).unwrap();

        let m = alice.encrypt(b"for bob only", b"").unwrap();
        assert!(other_bob.decrypt(&m, b"").is_err());
    }

    #[test]
    fn ratchet_headers_carry_post_quantum_material() {
        // Each header carries an ML-KEM encapsulation key (1184) and ciphertext
        // (1088) alongside the X25519 ratchet key — the machinery of the
        // ongoing PQ ratchet (§4). Size is the visible proof it is present.
        let bob = bob_secrets(true);
        let (_initial, mut alice) =
            establish_initiator(&alice_identity(), &bob.public_bundle()).unwrap();
        let m = alice.encrypt(b"pq", b"").unwrap();
        assert_eq!(m.header.len(), 32 + 1184 + 1088 + 4 + 4);
    }

    #[test]
    fn tampering_the_kem_ciphertext_breaks_a_ratchet_message() {
        // Bob's reply triggers Alice's DH+KEM ratchet. Corrupting the KEM
        // ciphertext field of its header makes the mixed secret (and the
        // header-as-AAD) wrong, so Alice cannot open it.
        let bob = bob_secrets(true);
        let (initial, mut alice) =
            establish_initiator(&alice_identity(), &bob.public_bundle()).unwrap();
        let mut bob = establish_responder(bob, &initial).unwrap();

        let m1 = alice.encrypt(b"hi", b"").unwrap();
        assert_eq!(bob.decrypt(&m1, b"").unwrap(), b"hi");

        let mut reply = bob.encrypt(b"hey", b"").unwrap();
        // Flip a byte inside the KEM ciphertext region (after x_pub + kem_ek).
        let kem_ct_start = 32 + 1184;
        reply.header[kem_ct_start] ^= 1;
        assert!(alice.decrypt(&reply, b"").is_err());
    }
}
