//! # aegis-identity — Phase 0
//!
//! Aegis identities, human-facing Aegis IDs, and **stealth addressing** for
//! recipient anonymity. This is the first crate of the Aegis messenger; it
//! implements Layer 1 of [`AEGIS_PROTOCOL.md`](../../../AEGIS_PROTOCOL.md),
//! with the exact construction and proofs in
//! [`docs/CRYPTO_MATH.md`](../../../docs/CRYPTO_MATH.md) §1–§2.1.
//!
//! Zero third-party dependencies: the cryptographic primitives (X25519,
//! SHA-256, HMAC/HKDF, ML-DSA-65) live in the `aegis-crypto` crate and are
//! verified against official RFC/FIPS test vectors.
//!
//! ## Quick tour
//!
//! ```
//! use aegis_identity::{Identity, stealth};
//!
//! // Bob publishes his Aegis ID; Alice decodes it.
//! let bob = Identity::generate();
//! let bob_id = bob.aegis_id().encode();
//! let bob_pub = aegis_identity::AegisId::decode(&bob_id).unwrap();
//!
//! // Alice derives a one-time stealth address to Bob's view key.
//! let (address, ephemeral) = stealth::create(&bob_pub.view_public()).unwrap();
//!
//! // Bob scans an incoming envelope and recognizes it as his.
//! assert!(bob.view().matches(&ephemeral, &address));
//! ```

pub mod identity;
pub mod stealth;

pub use identity::{AegisId, AegisIdError, Identity, ViewKeypair};
pub use stealth::{EphemeralPublic, StealthAddress, StealthError, ViewPublicKey, ADDR_TAG_LEN};

#[cfg(test)]
mod tests {
    use super::*;

    // Deterministic seeds so failures are reproducible.
    fn seed(byte: u8) -> [u8; 32] {
        [byte; 32]
    }

    #[test]
    fn recipient_recognizes_their_own_address() {
        let bob = Identity::from_secret_bytes(seed(1), seed(2), seed((1 ^ 2) ^ 0x5a));
        let (address, ephemeral) = stealth::create(&bob.view_public()).unwrap();
        assert!(bob.view().matches(&ephemeral, &address));
    }

    #[test]
    fn a_different_recipient_does_not_match() {
        let bob = Identity::from_secret_bytes(seed(1), seed(2), seed((1 ^ 2) ^ 0x5a));
        let mallory = Identity::from_secret_bytes(seed(3), seed(4), seed((3 ^ 4) ^ 0x5a));
        let (address, ephemeral) = stealth::create(&bob.view_public()).unwrap();
        assert!(!mallory.view().matches(&ephemeral, &address));
        // ...and Bob still matches, to rule out a trivially-broken derivation.
        assert!(bob.view().matches(&ephemeral, &address));
    }

    #[test]
    fn sender_and_recipient_derive_the_same_address() {
        // create_with_ephemeral (sender) vs. recomputation inside matches()
        // (recipient) must agree — this is the §1.3 correctness property.
        let bob = Identity::from_secret_bytes(seed(7), seed(8), seed((7 ^ 8) ^ 0x5a));
        let (address, ephemeral) =
            stealth::create_with_ephemeral(&bob.view_public(), seed(42)).unwrap();
        assert!(bob.view().matches(&ephemeral, &address));
    }

    #[test]
    fn derivation_is_deterministic_for_fixed_ephemeral() {
        let bob = Identity::from_secret_bytes(seed(1), seed(2), seed((1 ^ 2) ^ 0x5a));
        let a = stealth::create_with_ephemeral(&bob.view_public(), seed(99)).unwrap();
        let b = stealth::create_with_ephemeral(&bob.view_public(), seed(99)).unwrap();
        assert_eq!(a.0, b.0);
        assert_eq!(a.1, b.1);
    }

    #[test]
    fn addresses_to_one_recipient_are_unlinkable() {
        // 256 messages to the same recipient must all carry distinct address
        // tags and distinct ephemerals — the relay sees no repeats (§1.4).
        let bob = Identity::from_secret_bytes(seed(5), seed(6), seed((5 ^ 6) ^ 0x5a));
        let mut tags = std::collections::HashSet::new();
        let mut ephemerals = std::collections::HashSet::new();
        for i in 0..256u32 {
            // Vary bytes 8..12 only: X25519 clamps the low 3 bits of byte 0
            // and the top bits of byte 31, so a counter in the low bytes would
            // collide after clamping. The middle bytes survive untouched.
            let mut r = [0x11u8; 32];
            r[8..12].copy_from_slice(&i.to_le_bytes());
            let (address, ephemeral) =
                stealth::create_with_ephemeral(&bob.view_public(), r).unwrap();
            assert!(tags.insert(address.addr_tag), "duplicate addr_tag at {i}");
            assert!(ephemerals.insert(ephemeral.0), "duplicate ephemeral at {i}");
        }
    }

    #[test]
    fn tampered_address_tag_does_not_match() {
        let bob = Identity::from_secret_bytes(seed(1), seed(2), seed((1 ^ 2) ^ 0x5a));
        let (mut address, ephemeral) = stealth::create(&bob.view_public()).unwrap();
        address.addr_tag[0] ^= 0x01;
        assert!(!bob.view().matches(&ephemeral, &address));
    }

    #[test]
    fn tampered_ephemeral_does_not_match() {
        let bob = Identity::from_secret_bytes(seed(1), seed(2), seed((1 ^ 2) ^ 0x5a));
        let (address, mut ephemeral) = stealth::create(&bob.view_public()).unwrap();
        ephemeral.0[0] ^= 0x01;
        assert!(!bob.view().matches(&ephemeral, &address));
    }

    #[test]
    fn degenerate_recipient_key_is_rejected() {
        // A small-order view key (u = 0) forces an all-zero shared secret,
        // which the RFC 7748 §6.1 check must reject rather than derive a tag.
        let degenerate = ViewPublicKey([0u8; 32]);
        assert_eq!(
            stealth::create_with_ephemeral(&degenerate, seed(1)),
            Err(StealthError::DegenerateSharedSecret)
        );
    }

    #[test]
    fn scanning_a_degenerate_envelope_is_a_non_match_not_a_panic() {
        let bob = Identity::from_secret_bytes(seed(1), seed(2), seed((1 ^ 2) ^ 0x5a));
        let address = StealthAddress {
            addr_tag: [0u8; ADDR_TAG_LEN],
            view_tag: 0,
        };
        assert!(!bob.view().matches(&EphemeralPublic([0u8; 32]), &address));
    }

    #[test]
    fn aegis_id_round_trips() {
        let id = Identity::from_secret_bytes(seed(10), seed(20), seed((10 ^ 20) ^ 0x5a)).aegis_id();
        let encoded = id.encode();
        assert!(encoded.starts_with("aegis:"));
        let decoded = AegisId::decode(&encoded).unwrap();
        assert_eq!(id, decoded);
        assert_eq!(decoded.view_public(), ViewPublicKey(id.view_public().0));
    }

    #[test]
    fn aegis_id_carries_the_right_keys() {
        let identity = Identity::from_secret_bytes(seed(10), seed(20), seed((10 ^ 20) ^ 0x5a));
        let id = identity.aegis_id();
        assert_eq!(id.identity_dh_public(), identity.identity_dh_public());
        assert_eq!(id.view_public(), identity.view_public());
    }

    #[test]
    fn decoded_aegis_id_addresses_the_real_recipient() {
        // End-to-end: decode Bob's shared ID, send to it, Bob recognizes it.
        let bob = Identity::from_secret_bytes(seed(11), seed(22), seed((11 ^ 22) ^ 0x5a));
        let shared = bob.aegis_id().encode();
        let bob_pub = AegisId::decode(&shared).unwrap();
        let (address, ephemeral) = stealth::create(&bob_pub.view_public()).unwrap();
        assert!(bob.view().matches(&ephemeral, &address));
    }

    #[test]
    fn corrupted_aegis_id_fails_checksum() {
        let encoded = Identity::from_secret_bytes(seed(1), seed(2), seed((1 ^ 2) ^ 0x5a))
            .aegis_id()
            .encode();
        // Flip one character in the payload region (after the "aegis:" prefix).
        let mut chars: Vec<char> = encoded.chars().collect();
        let idx = 10;
        chars[idx] = if chars[idx] == 'a' { 'b' } else { 'a' };
        let corrupted: String = chars.into_iter().collect();
        match AegisId::decode(&corrupted) {
            Err(AegisIdError::BadChecksum) | Err(AegisIdError::BadVersion) => {}
            other => panic!("expected checksum/version rejection, got {other:?}"),
        }
    }

    #[test]
    fn aegis_id_bad_prefix_is_rejected() {
        assert_eq!(AegisId::decode("nope:abc"), Err(AegisIdError::BadPrefix));
    }

    #[test]
    fn identity_signs_and_verifies() {
        use aegis_crypto::ml_dsa;
        let bob = Identity::from_secret_bytes(seed(1), seed(2), seed(3));
        let sig = bob.sign(b"prekey bundle bytes");
        assert!(ml_dsa::verify(
            bob.signing_public(),
            b"prekey bundle bytes",
            &sig
        ));
        // A different message does not verify under the same signature.
        assert!(!ml_dsa::verify(
            bob.signing_public(),
            b"tampered bytes",
            &sig
        ));
    }

    #[test]
    fn aegis_id_binds_the_signing_key() {
        let bob = Identity::from_secret_bytes(seed(1), seed(2), seed(3));
        let id = bob.aegis_id();
        // The real signing key matches the ID's commitment...
        assert!(id.verify_signing_key(bob.signing_public()));
        // ...but a different identity's signing key does not (substitution).
        let mallory = Identity::from_secret_bytes(seed(4), seed(5), seed(6));
        assert!(!id.verify_signing_key(mallory.signing_public()));
    }

    #[test]
    fn aegis_id_round_trip_preserves_the_signing_hash() {
        let id = Identity::from_secret_bytes(seed(10), seed(20), seed(30)).aegis_id();
        let decoded = AegisId::decode(&id.encode()).unwrap();
        assert_eq!(decoded, id);
        assert_eq!(decoded.signing_key_hash(), id.signing_key_hash());
    }
}
