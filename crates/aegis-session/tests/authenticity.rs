//! End-to-end authenticity (G8): the full chain from a shareable Aegis ID to a
//! verified, identity-bound prekey bundle.
//!
//! `aegis-session` signs and verifies a bundle's *self-consistency* (the
//! signature matches the advertised signing key), and `aegis-identity`'s
//! `AegisId` commits to `SHA-256(IK^sig)`. Binding the two — "this bundle's
//! signing key really is the one behind Bob's Aegis ID" — is what defeats a
//! man-in-the-middle who swaps in their own bundle. These tests exercise that
//! binding across both crates.

use aegis_crypto::x25519::SecretKey;
use aegis_identity::{AegisId, Identity};
use aegis_session::{establish_initiator, establish_responder, PrekeySecrets};

/// Build Bob's identity and a prekey bundle backed by the *same* long-term
/// keys, the way a real client would (a later phase folds this into one type).
fn bob_identity_and_secrets() -> (Identity, PrekeySecrets) {
    let identity_dh = [1u8; 32];
    let view = [2u8; 32];
    let signing_seed = [3u8; 32];
    let identity = Identity::from_secret_bytes(identity_dh, view, signing_seed);
    let secrets = PrekeySecrets::from_seeds(
        identity_dh,     // same identity DH key as the Identity
        [4u8; 32],       // signed prekey
        [5u8; 32],       // ML-KEM d
        [6u8; 32],       // ML-KEM z
        Some([7u8; 32]), // one-time prekey
        signing_seed,    // same signing key as the Identity
    );
    (identity, secrets)
}

#[test]
fn aegis_id_binds_the_bundle_signing_key() {
    let (identity, secrets) = bob_identity_and_secrets();
    let aegis_id = identity.aegis_id();
    let bundle = secrets.public_bundle();

    // The bundle is internally consistent...
    assert!(bundle.verify());
    // ...its identity DH key matches the ID...
    assert_eq!(bundle.identity_dh, aegis_id.identity_dh_public());
    // ...and its signing key is exactly the one Bob's Aegis ID commits to.
    assert!(aegis_id.verify_signing_key(&bundle.identity_signing_public));
    assert_eq!(bundle.signing_key_hash(), aegis_id.signing_key_hash());
}

#[test]
fn mitm_bundle_from_a_different_key_is_caught_by_the_binding() {
    // Bob's real Aegis ID, shared out of band.
    let (bob, _) = bob_identity_and_secrets();
    let bob_id_string = bob.aegis_id().encode();
    let bob_id = AegisId::decode(&bob_id_string).unwrap();

    // A man-in-the-middle publishes their OWN valid, self-consistent bundle.
    let mallory = PrekeySecrets::from_seeds(
        [10u8; 32],
        [11u8; 32],
        [12u8; 32],
        [13u8; 32],
        Some([14u8; 32]),
        [15u8; 32],
    );
    let forged = mallory.public_bundle();

    // The signature verifies on its own (Mallory signed it correctly)...
    assert!(forged.verify());
    // ...but its signing key is NOT the one Bob's Aegis ID commits to, so the
    // binding check rejects it. This is what a client must do before trusting.
    assert!(!bob_id.verify_signing_key(&forged.identity_signing_public));
}

#[test]
fn a_verified_bound_bundle_yields_a_working_session() {
    let (bob_identity, bob_secrets) = bob_identity_and_secrets();
    let bob_id = bob_identity.aegis_id();
    let bundle = bob_secrets.public_bundle();

    // Client-side check a real initiator performs before establishing.
    assert!(bundle.verify());
    assert!(bob_id.verify_signing_key(&bundle.identity_signing_public));

    let alice_identity = SecretKey::from_bytes([9u8; 32]);
    let (initial, mut alice) = establish_initiator(&alice_identity, &bundle).unwrap();
    let mut bob = establish_responder(bob_secrets, &initial).unwrap();

    let m = alice.encrypt(b"authenticated hello", b"").unwrap();
    assert_eq!(bob.decrypt(&m, b"").unwrap(), b"authenticated hello");
}
