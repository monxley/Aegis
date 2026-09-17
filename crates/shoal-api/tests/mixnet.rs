//! End-to-end over the **mixnet**: a provider (blind mailbox + mix), a forwarder
//! mix, and two `ShoalApp`s that auto-discover the network and exchange a message
//! onion-routed through the forwarder to the provider. No app runs a relay.

use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use shoal_api::ShoalApp;
use shoal_mix::{spawn_forwarder, DirectoryState, MailboxDeliver, MixService, NodeDescriptor};
use shoal_net::MixNode;
use shoal_relay::CiphraStore;

use ciphra_net::{serve, SharedStorage};
use ciphra_storage::Storage;

/// Spawn a Ciphra blind server (the provider's mailbox); return its address.
/// Also lowers node-admission PoW so the in-process tests stay fast (production
/// difficulty is much higher); both tests call this before spawning any node.
fn spawn_ciphra() -> std::net::SocketAddr {
    shoal_mix::set_pow_difficulty(6);
    let mut rand = [0u8; 8];
    shoal_crypto::fill_random(&mut rand);
    let dir = std::env::temp_dir().join(format!("shoal-mixtest-{}", u64::from_le_bytes(rand)));
    let storage = Storage::open(&dir).expect("open storage");
    let shared = SharedStorage::new(storage);
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().unwrap();
    thread::spawn(move || {
        let _ = serve(listener, shared, [7u8; 32]);
    });
    thread::sleep(Duration::from_millis(100));
    addr
}

/// Spawn a provider node: a mix whose exit delivers into its Ciphra mailbox.
fn spawn_provider(seed: u8, ciphra_addr: std::net::SocketAddr) -> NodeDescriptor {
    let node = MixNode::from_seed(&[seed; 32]);
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let mix_addr = listener.local_addr().unwrap();
    let desc = NodeDescriptor::new(node.public_hop(), mix_addr, Some(ciphra_addr));
    let mailbox = CiphraStore::connect(ciphra_addr, None).expect("connect provider mailbox");
    let deliver = MailboxDeliver(Arc::new(Mutex::new(mailbox)));
    let directory = DirectoryState::with_nodes(std::slice::from_ref(&desc));
    let service = MixService::new(node, directory, deliver);
    thread::spawn(move || {
        let _ = service.serve(listener);
    });
    desc
}

fn poll_until(app: &mut ShoalApp, want: usize) -> Vec<shoal_api::IncomingMessage> {
    let mut all = Vec::new();
    for _ in 0..100 {
        all.extend(app.poll().expect("poll").messages);
        if all.len() >= want {
            return all;
        }
        thread::sleep(Duration::from_millis(50));
    }
    all
}

#[test]
fn two_apps_talk_over_the_auto_discovered_mixnet() {
    // Provider (mailbox + mix), then a forwarder that learns it from bootstrap.
    let ciphra = spawn_ciphra();
    let provider = spawn_provider(200, ciphra);
    let forwarder =
        spawn_forwarder([201u8; 32], "127.0.0.1:0", &[provider.mix_addr], None).expect("forwarder");
    // Discovering from the forwarder yields both nodes.
    let boot = vec![forwarder.mix_addr.to_string()];

    // Neither app is configured with a relay: they auto-discover and route.
    let mut alice = ShoalApp::create_on_network(vec![1u8; 32], boot.clone()).expect("alice net");
    let mut bob = ShoalApp::create_on_network(vec![2u8; 32], boot).expect("bob net");

    alice
        .add_contact("Bob".into(), bob.my_shoal_id(), bob.my_bundle())
        .unwrap();
    bob.add_contact("Alice".into(), alice.my_shoal_id(), alice.my_bundle())
        .unwrap();

    // Alice sends; the message onion-routes forwarder -> provider (which stores
    // it in the blind mailbox). Bob polls the provider and reads it.
    alice
        .send(bob.my_shoal_id(), "hi over the mixnet".into())
        .unwrap();
    let got = poll_until(&mut bob, 1);
    assert_eq!(got.len(), 1, "bob should receive one message");
    assert_eq!(got[0].text, "hi over the mixnet");
    assert_eq!(got[0].from_name.as_deref(), Some("Alice"));

    // And a reply the other way.
    bob.send(alice.my_shoal_id(), "got it".into()).unwrap();
    let got = poll_until(&mut alice, 1);
    assert_eq!(got[0].text, "got it");
}

#[test]
fn bob_receives_anonymously_over_surbs() {
    // Alice sends normally; Bob runs a node and polls his provider *through the
    // mixnet* with SURBs, so the provider never learns Bob is the one polling.
    let ciphra = spawn_ciphra();
    let provider = spawn_provider(210, ciphra);
    let forwarder =
        spawn_forwarder([211u8; 32], "127.0.0.1:0", &[provider.mix_addr], None).expect("forwarder");
    // Let the provider learn the forwarder (needed to route SURB replies).
    shoal_mix::announce(provider.mix_addr, std::slice::from_ref(&forwarder)).unwrap();
    thread::sleep(Duration::from_millis(100));

    let boot = vec![provider.mix_addr.to_string()];
    let mut alice = ShoalApp::create_on_network(vec![1u8; 32], boot.clone()).expect("alice");
    let mut bob =
        ShoalApp::create_on_network_with_receive(vec![2u8; 32], boot, "127.0.0.1:0".into())
            .expect("bob anon");

    alice
        .add_contact("Bob".into(), bob.my_shoal_id(), bob.my_bundle())
        .unwrap();
    alice.send(bob.my_shoal_id(), "anon hello".into()).unwrap();

    // Bob's first poll issues the anonymous fetch; a later one harvests the SURB
    // reply. The message arrives without the provider seeing Bob.
    let got = poll_until(&mut bob, 1);
    assert_eq!(got.len(), 1, "bob should receive one message anonymously");
    assert_eq!(got[0].text, "anon hello");
}

fn poll_until_status(app: &mut ShoalApp, peer: &str, want: u8) {
    for _ in 0..100 {
        let _ = app.poll();
        if app
            .history(peer.to_string())
            .iter()
            .any(|m| m.from_me && m.status >= want)
        {
            return;
        }
        thread::sleep(Duration::from_millis(50));
    }
    panic!("status {want} not reached for {peer}");
}

#[test]
fn delivery_and_read_receipts() {
    let ciphra = spawn_ciphra();
    let provider = spawn_provider(230, ciphra);
    let boot = vec![provider.mix_addr.to_string()];
    let mut alice = ShoalApp::create_on_network(vec![1u8; 32], boot.clone()).unwrap();
    let mut bob = ShoalApp::create_on_network(vec![2u8; 32], boot).unwrap();
    alice
        .add_contact("Bob".into(), bob.my_shoal_id(), bob.my_bundle())
        .unwrap();
    bob.add_contact("Alice".into(), alice.my_shoal_id(), alice.my_bundle())
        .unwrap();

    alice.send(bob.my_shoal_id(), "hi".into()).unwrap();
    assert_eq!(alice.history(bob.my_shoal_id())[0].status, 0, "starts sent");

    // Bob receives the text and auto-emits a delivered receipt.
    assert_eq!(poll_until(&mut bob, 1).len(), 1);

    // Alice polls and sees "delivered".
    poll_until_status(&mut alice, &bob.my_shoal_id(), 1);

    // Bob opens the chat -> read receipt -> Alice sees "read".
    bob.mark_read(alice.my_shoal_id()).unwrap();
    poll_until_status(&mut alice, &bob.my_shoal_id(), 2);
}
