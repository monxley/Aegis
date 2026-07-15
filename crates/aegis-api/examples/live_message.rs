//! A real end-to-end run of the Aegis engine.
//!
//! Spins up a **live Ciphra blind server** in-process, creates two
//! [`AegisApp`]s (the exact engine the Flutter UI drives) pointed at it,
//! exchanges identities, and sends a message each way over the real relay.
//! Every byte the server stores is an already-sealed Aegis envelope.
//!
//! Run it:  `cargo run -p aegis-api --example live_message`

use std::net::TcpListener;
use std::thread;
use std::time::Duration;

use aegis_api::AegisApp;
use ciphra_net::{serve, SharedStorage};
use ciphra_storage::Storage;

fn spawn_blind_server() -> std::net::SocketAddr {
    let mut rand = [0u8; 8];
    aegis_crypto::fill_random(&mut rand);
    let dir = std::env::temp_dir().join(format!("aegis-demo-{}", u64::from_le_bytes(rand)));
    let storage = Storage::open(&dir).expect("open ciphra storage");
    let shared = SharedStorage::new(storage);
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    thread::spawn(move || {
        let _ = serve(listener, shared, [7u8; 32]);
    });
    addr
}

fn main() {
    println!("── Aegis live demo ─────────────────────────────────────────");

    let addr = spawn_blind_server();
    println!("• Ciphra blind server listening on {addr}");
    // Give the listener a moment to come up before the clients connect.
    thread::sleep(Duration::from_millis(150));

    // Two users, each a fresh identity, both connected to the same relay.
    let mut alice = AegisApp::create_with_relay(vec![1u8; 32], addr.to_string())
        .expect("alice connects to relay");
    let mut bob = AegisApp::create_with_relay(vec![2u8; 32], addr.to_string())
        .expect("bob connects to relay");
    println!("• Alice: {}", alice.my_aegis_id());
    println!("• Bob:   {}", bob.my_aegis_id());

    // They exchange Aegis IDs + prekey bundles out of band (paste / QR) and add
    // each other as contacts.
    alice
        .add_contact("Bob".into(), bob.my_aegis_id(), bob.my_bundle())
        .expect("alice adds bob");
    bob.add_contact("Alice".into(), alice.my_aegis_id(), alice.my_bundle())
        .expect("bob adds alice");
    println!("• Contacts exchanged.\n");

    // Alice sends. This seals the message and stores it on the blind server.
    let msg = "hello Bob — this is Aegis, end-to-end & post-quantum";
    alice
        .send(bob.my_aegis_id(), msg.into())
        .expect("alice sends");
    println!("→ Alice sent:  \"{msg}\"");

    // Bob polls the live relay, decrypts, and reads it.
    let inbox = bob.poll().expect("bob polls");
    assert_eq!(inbox.len(), 1, "bob should receive exactly one message");
    let got = &inbox[0];
    println!(
        "← Bob got:     \"{}\"   (from {})",
        got.text,
        got.from_name.as_deref().unwrap_or("unknown")
    );
    assert_eq!(got.text, msg);

    // Bob replies on the now-established session.
    let reply = "got it, Alice — nobody in between can read this";
    bob.send(alice.my_aegis_id(), reply.into())
        .expect("bob replies");
    println!("→ Bob sent:    \"{reply}\"");

    let inbox = alice.poll().expect("alice polls");
    assert_eq!(inbox.len(), 1);
    println!(
        "← Alice got:   \"{}\"   (from {})",
        inbox[0].text,
        inbox[0].from_name.as_deref().unwrap_or("unknown")
    );
    assert_eq!(inbox[0].text, reply);

    println!("\n✓ Round-trip verified over a live blind relay.");
    println!(
        "  Alice's history with Bob: {} messages.",
        alice.history(bob.my_aegis_id()).len()
    );
    println!("────────────────────────────────────────────────────────────");
}
