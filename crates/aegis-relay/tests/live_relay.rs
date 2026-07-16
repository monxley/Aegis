//! End-to-end over a **live Ciphra blind server**: an in-process `ciphra-server`
//! is the relay, and two `AegisClient`s hold a conversation through it — every
//! byte the server stores is an already-sealed Aegis envelope, so it learns
//! neither who the messages are for nor from.

use std::net::TcpListener;
use std::thread;

use aegis_client::AegisClient;
use aegis_relay::CiphraStore;
use ciphra_net::{serve, SharedStorage};
use ciphra_storage::Storage;

/// Spawn a Ciphra blind server on an ephemeral port; return its address.
fn spawn_blind_server() -> std::net::SocketAddr {
    let mut rand = [0u8; 8];
    aegis_crypto::fill_random(&mut rand);
    let dir = std::env::temp_dir().join(format!("aegis-ciphra-{}", u64::from_le_bytes(rand)));

    let storage = Storage::open(&dir).expect("open ciphra storage");
    let shared = SharedStorage::new(storage);
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");

    // The server's static transport key. It authenticates the server; it can
    // never decrypt stored rows (ADR-0003).
    let server_secret = [7u8; 32];
    thread::spawn(move || {
        let _ = serve(listener, shared, server_secret);
    });
    addr
}

#[test]
fn a_conversation_flows_through_a_live_ciphra_relay() {
    let addr = spawn_blind_server();

    let mut alice = AegisClient::from_master_seed([1u8; 32]);
    let mut bob = AegisClient::from_master_seed([2u8; 32]);

    // The relay is a real Ciphra blind server reached over its post-quantum
    // channel (trust-on-first-use here; pin the key in production).
    let mut relay = CiphraStore::connect(addr, None).expect("connect to ciphra");

    // Alice opens a conversation; the server just stores a sealed envelope.
    alice
        .start_conversation(
            &mut relay,
            &bob.aegis_id(),
            &bob.bundle(),
            b"hi bob over ciphra",
        )
        .unwrap();

    // Bob scans the live relay and reads it.
    let got = bob.receive(&relay).unwrap();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].message, b"hi bob over ciphra");
    assert_eq!(got[0].from, alice.aegis_id());

    // Bob replies over the same relay; Alice reads it.
    bob.send(&mut relay, &alice.aegis_id(), b"hi alice over ciphra")
        .unwrap();
    let got = alice.receive(&relay).unwrap();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].message, b"hi alice over ciphra");
}

#[test]
fn many_turns_persist_in_the_live_relay() {
    let addr = spawn_blind_server();
    let mut alice = AegisClient::from_master_seed([1u8; 32]);
    let mut bob = AegisClient::from_master_seed([2u8; 32]);
    let mut relay = CiphraStore::connect(addr, None).expect("connect");

    alice
        .start_conversation(&mut relay, &bob.aegis_id(), &bob.bundle(), b"turn 0")
        .unwrap();
    assert_eq!(bob.receive(&relay).unwrap()[0].message, b"turn 0");

    for i in 1..6u8 {
        bob.send(&mut relay, &alice.aegis_id(), &[i]).unwrap();
        assert_eq!(alice.receive(&relay).unwrap()[0].message, vec![i]);
        alice
            .send(&mut relay, &bob.aegis_id(), &[i ^ 0xff])
            .unwrap();
        assert_eq!(bob.receive(&relay).unwrap()[0].message, vec![i ^ 0xff]);
    }
}

#[test]
fn sweep_deletes_stored_messages_but_a_seq_cursor_survives_it() {
    use aegis_mailbox::MailboxStore;
    use std::time::Duration;
    let addr = spawn_blind_server();
    let mut store = CiphraStore::connect(addr, None).unwrap();

    let mut alice = AegisClient::from_master_seed([1u8; 32]);
    let bob = AegisClient::from_master_seed([2u8; 32]);
    alice
        .start_conversation(&mut store, &bob.aegis_id(), &bob.bundle(), b"hi")
        .unwrap();

    // The message is stored and fetchable from the start.
    let (cursor, msgs) = store.fetch_since(0).unwrap();
    assert_eq!(msgs.len(), 1, "one stored envelope");

    // Sweeping everything older than 0ms removes it.
    std::thread::sleep(Duration::from_millis(5));
    assert_eq!(store.sweep(0).unwrap(), 1, "one message swept");
    assert!(store.fetch_since(0).unwrap().1.is_empty(), "mailbox emptied");

    // A caught-up recipient (cursor past the deleted seq) still receives the
    // NEXT message — deletion doesn't shift the sequence-based cursor.
    alice
        .send(&mut store, &bob.aegis_id(), b"after sweep")
        .unwrap();
    let (_c2, msgs2) = store.fetch_since(cursor).unwrap();
    assert_eq!(msgs2.len(), 1, "the post-sweep message arrives at the old cursor");
}
