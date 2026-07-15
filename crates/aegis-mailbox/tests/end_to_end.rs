//! End-to-end: a real Double Ratchet message travels through the blind mailbox.
//!
//! This exercises all three layers composing — stealth addressing (Phase 0),
//! the post-quantum session (Phase 1), and sealed-sender store-and-forward
//! delivery (Phase 2): Alice encrypts with the ratchet, seals the result into
//! an envelope addressed to Bob's view key, and drops it on a relay that learns
//! nothing; Bob scans the relay, recovers the message, and decrypts it.

use aegis_crypto::x25519::SecretKey;
use aegis_identity::Identity;
use aegis_mailbox::{receive, send, InMemoryStore};
use aegis_session::{establish_initiator, establish_responder, Message, PrekeySecrets};

/// Minimal wire encoding for a ratchet [`Message`]: `len(header) ‖ header ‖ ct`.
fn serialize(m: &Message) -> Vec<u8> {
    let mut out = (m.header.len() as u32).to_le_bytes().to_vec();
    out.extend_from_slice(&m.header);
    out.extend_from_slice(&m.ciphertext);
    out
}

fn deserialize(bytes: &[u8]) -> Message {
    let header_len = u32::from_le_bytes(bytes[..4].try_into().unwrap()) as usize;
    Message {
        header: bytes[4..4 + header_len].to_vec(),
        ciphertext: bytes[4 + header_len..].to_vec(),
    }
}

fn bob() -> (Identity, PrekeySecrets) {
    // Same person: a long-term view identity that addresses envelopes, plus
    // session prekeys. (A later phase folds these into one type.)
    let identity = Identity::from_secret_bytes([1u8; 32], [2u8; 32], [3u8; 32]);
    let secrets = PrekeySecrets::from_seeds(
        [4u8; 32],
        [5u8; 32],
        [6u8; 32],
        [7u8; 32],
        Some([8u8; 32]),
        [9u8; 32],
        [10u8; 32],
    );
    (identity, secrets)
}

#[test]
fn message_travels_through_the_blind_mailbox() {
    let (bob_identity, bob_secrets) = bob();

    // Session setup (the initial handshake message is delivered out of band).
    let alice_identity = SecretKey::from_bytes([11u8; 32]);
    let (initial, mut alice) =
        establish_initiator(&alice_identity, &bob_secrets.public_bundle()).unwrap();
    let mut bob_session = establish_responder(bob_secrets, &initial).unwrap();

    // Alice ratchet-encrypts, then seals the result into a mailbox envelope
    // addressed to Bob's *view* key and drops it on the relay.
    let mut store = InMemoryStore::new();
    let outgoing = alice.encrypt(b"through the void", b"").unwrap();
    send(
        &mut store,
        &bob_identity.view_public(),
        &serialize(&outgoing),
    )
    .unwrap();

    // The relay holds exactly one opaque envelope.
    assert_eq!(store.len(), 1);

    // Bob scans the relay, recovers the ratchet message, and decrypts it.
    let (_cursor, inners) = receive(&store, bob_identity.view(), 0).unwrap();
    assert_eq!(inners.len(), 1);
    let recovered = deserialize(&inners[0]);
    assert_eq!(
        bob_session.decrypt(&recovered, b"").unwrap(),
        b"through the void"
    );
}

#[test]
fn a_stranger_scanning_the_mailbox_learns_nothing() {
    let (bob_identity, bob_secrets) = bob();
    let alice_identity = SecretKey::from_bytes([11u8; 32]);
    let (initial, mut alice) =
        establish_initiator(&alice_identity, &bob_secrets.public_bundle()).unwrap();
    let _bob_session = establish_responder(bob_secrets, &initial).unwrap();

    let mut store = InMemoryStore::new();
    let outgoing = alice.encrypt(b"secret", b"").unwrap();
    send(
        &mut store,
        &bob_identity.view_public(),
        &serialize(&outgoing),
    )
    .unwrap();

    // A different identity scanning the same relay recovers nothing.
    let stranger = Identity::from_secret_bytes([90u8; 32], [91u8; 32], [92u8; 32]);
    let (_, inners) = receive(&store, stranger.view(), 0).unwrap();
    assert!(inners.is_empty());
}

#[test]
fn a_multi_message_conversation_flows_through_the_mailbox() {
    let (bob_identity, bob_secrets) = bob();
    let alice_view = Identity::from_secret_bytes([20u8; 32], [21u8; 32], [22u8; 32]);
    let alice_identity = SecretKey::from_bytes([11u8; 32]);

    let (initial, mut alice) =
        establish_initiator(&alice_identity, &bob_secrets.public_bundle()).unwrap();
    let mut bob_session = establish_responder(bob_secrets, &initial).unwrap();

    let mut store = InMemoryStore::new();
    let mut bob_cursor = 0;
    let mut alice_cursor = 0;

    // Alice -> Bob, then Bob -> Alice, a few round trips, all via the relay.
    for i in 0..4u8 {
        let a = alice.encrypt(&[i; 8], b"").unwrap();
        send(&mut store, &bob_identity.view_public(), &serialize(&a)).unwrap();
        let (c, got) = receive(&store, bob_identity.view(), bob_cursor).unwrap();
        bob_cursor = c;
        assert_eq!(got.len(), 1);
        assert_eq!(
            bob_session.decrypt(&deserialize(&got[0]), b"").unwrap(),
            vec![i; 8]
        );

        let b = bob_session.encrypt(&[i ^ 0xff; 8], b"").unwrap();
        send(&mut store, &alice_view.view_public(), &serialize(&b)).unwrap();
        let (c, got) = receive(&store, alice_view.view(), alice_cursor).unwrap();
        alice_cursor = c;
        assert_eq!(got.len(), 1);
        assert_eq!(
            alice.decrypt(&deserialize(&got[0]), b"").unwrap(),
            vec![i ^ 0xff; 8]
        );
    }
}
