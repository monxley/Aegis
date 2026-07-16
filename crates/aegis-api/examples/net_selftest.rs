//! Network self-test: drive two throwaway identities through a **live** Aegis
//! node and report whether a message (and its delivery receipt) makes the full
//! round trip. Run it on a machine with a stable connection (e.g. the VPS that
//! hosts the node) to tell a node/delivery problem apart from a phone's mobile
//! network:
//!
//! ```sh
//! cargo run -p aegis-api --example net_selftest -- 135.181.125.178:5078
//! ```
//!
//! It uses fresh random-looking identities, sends one message each way, and
//! prints the delivery status (0 sent · 1 delivered · 2 read). If it reaches
//! "delivered" here but phones still fail, the node is fine and the problem is
//! the phone's network path.

use std::thread;
use std::time::{Duration, Instant};

use aegis_api::AegisApp;

fn main() {
    let boot = std::env::args().nth(1).unwrap_or_else(|| {
        eprintln!("usage: net_selftest <bootstrap mix addr host:5078> [mailbox host:5077]");
        std::process::exit(2);
    });
    // The live network mines admission PoW at the production difficulty; match it
    // so the node's descriptor validates on discovery.
    aegis_mix::set_pow_difficulty(20);

    // Layer A — the mailbox alone (no mixnet): connect two clients DIRECTLY to
    // the provider's Ciphra server and pass a message. This isolates whether the
    // blind mailbox read/write works over the real network from whether the
    // onion path does. Mailbox addr defaults to the bootstrap host on :5077.
    let mailbox = std::env::args().nth(2).unwrap_or_else(|| {
        let host = boot.rsplit_once(':').map(|(h, _)| h).unwrap_or("127.0.0.1");
        format!("{host}:5077")
    });
    println!("── Layer A: direct mailbox round-trip via {mailbox} ──");
    match direct_mailbox_check(&mailbox) {
        Ok(true) => println!("✓ direct mailbox works — the blind server stores & serves fine."),
        Ok(false) => println!("✗ direct mailbox FAILED — the message never came back. The problem is the mailbox/network, not the mixnet."),
        Err(e) => println!("✗ direct mailbox errored: {e}"),
    }
    println!("── Layer B: full mixnet (onion-routed) round-trip ──");

    let mut seed_a = [0u8; 32];
    let mut seed_b = [0u8; 32];
    aegis_crypto::fill_random(&mut seed_a);
    aegis_crypto::fill_random(&mut seed_b);

    println!("• discovering the network from {boot} …");
    let mut alice = match AegisApp::create_on_network(seed_a.to_vec(), vec![boot.clone()]) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("✗ alice could not join the network: {e}");
            std::process::exit(1);
        }
    };
    let mut bob = match AegisApp::create_on_network(seed_b.to_vec(), vec![boot]) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("✗ bob could not join the network: {e}");
            std::process::exit(1);
        }
    };
    alice
        .add_contact("Bob".into(), bob.my_aegis_id(), bob.my_bundle())
        .unwrap();
    bob.add_contact("Alice".into(), alice.my_aegis_id(), alice.my_bundle())
        .unwrap();
    println!("• two identities created and introduced.");

    alice.send(bob.my_aegis_id(), "selftest ping".into()).unwrap();
    println!("→ alice sent \"selftest ping\"");

    // Bob polls for the message.
    let start = Instant::now();
    let mut got = false;
    for _ in 0..100 {
        let inbox = bob.poll().unwrap_or_default();
        if inbox.iter().any(|m| m.text == "selftest ping") {
            println!("← bob received it after {} ms", start.elapsed().as_millis());
            got = true;
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }
    if !got {
        println!("✗ bob NEVER received the message (10s). Delivery is broken at the node.");
        std::process::exit(1);
    }

    // Bob reads it; both receipts should flow back to alice.
    bob.mark_read(alice.my_aegis_id()).unwrap();
    let mut status = 0u8;
    for _ in 0..100 {
        let _ = alice.poll();
        status = alice
            .history(bob.my_aegis_id())
            .first()
            .map(|m| m.status)
            .unwrap_or(0);
        if status >= 2 {
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }
    match status {
        2 => println!("✓ full round trip: sent → delivered → read. The node is healthy."),
        1 => println!("~ delivered, but the read receipt didn't return (partial)."),
        _ => println!("~ message arrived but no delivery receipt came back (partial)."),
    }
}

/// Layer A: two clients connected straight to the provider's Ciphra mailbox
/// (no mixnet) exchange one message. Returns Ok(true) if it round-trips.
fn direct_mailbox_check(mailbox: &str) -> Result<bool, String> {
    let mut sa = [0u8; 32];
    let mut sb = [0u8; 32];
    aegis_crypto::fill_random(&mut sa);
    aegis_crypto::fill_random(&mut sb);
    let mut a = AegisApp::create_with_relay(sa.to_vec(), mailbox.to_string())
        .map_err(|e| e.to_string())?;
    let mut b = AegisApp::create_with_relay(sb.to_vec(), mailbox.to_string())
        .map_err(|e| e.to_string())?;
    a.add_contact("B".into(), b.my_aegis_id(), b.my_bundle())
        .map_err(|e| e.to_string())?;
    a.send(b.my_aegis_id(), "direct ping".into())
        .map_err(|e| e.to_string())?;
    for _ in 0..50 {
        let got = b.poll().unwrap_or_default();
        if got.iter().any(|m| m.text == "direct ping") {
            return Ok(true);
        }
        thread::sleep(Duration::from_millis(100));
    }
    Ok(false)
}
