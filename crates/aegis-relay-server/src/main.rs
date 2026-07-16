//! `aegis-relay-server` — run your own Aegis relay.
//!
//! A relay is a **Ciphra blind server**: it stores and serves sealed Aegis
//! envelopes and nothing else. It has no data keys, so it can neither read a
//! message nor tell who it is for or from — it only holds opaque bytes and
//! hands them back on request (ADR-0003). Put this on any host both
//! participants can reach (a VPS, a home server behind a forwarded port) and
//! point clients at it with `AegisApp::create_with_relay("host:5077")`.
//!
//! ```text
//! aegis-relay-server                 # 0.0.0.0:5077, data in ./aegis-relay-data
//! aegis-relay-server -l 0.0.0.0:5077 -d /var/lib/aegis-relay
//! ```
//!
//! The relay keeps a static transport identity in `<data>/relay_key` (created
//! on first run). Its public half is printed on startup; clients can **pin** it
//! to defeat a first-connection MITM. Delete the file only if you intend to
//! rotate the relay's identity (every pinning client must re-pin).

use std::net::{SocketAddr, TcpListener};
use std::path::Path;
use std::process::ExitCode;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use aegis_mix::{DirectoryState, MailboxDeliver, MixService, NodeDescriptor};
use aegis_net::MixNode;
use aegis_relay::CiphraStore;
use ciphra_crypto::ServerIdentity;
use ciphra_net::{serve, SharedStorage};
use ciphra_storage::Storage;

const DEFAULT_LISTEN: &str = "0.0.0.0:5077";
const DEFAULT_DATA_DIR: &str = "./aegis-relay-data";
const IDENTITY_FILE: &str = "relay_key";
const MIX_KEY_FILE: &str = "mix_key";

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("aegis-relay-server: error: {message}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let mut listen = DEFAULT_LISTEN.to_string();
    let mut data_dir = DEFAULT_DATA_DIR.to_string();
    let mut mix_listen: Option<String> = None;
    let mut advertise_mix: Option<String> = None;
    let mut advertise_provider: Option<String> = None;
    let mut bootstrap: Vec<String> = Vec::new();

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--listen" | "-l" => {
                listen = args
                    .next()
                    .ok_or("--listen requires an address, e.g. 0.0.0.0:5077")?;
            }
            "--data" | "-d" => {
                data_dir = args.next().ok_or("--data requires a directory")?;
            }
            "--mix" | "-m" => {
                mix_listen = Some(
                    args.next()
                        .ok_or("--mix requires an address, e.g. 0.0.0.0:5078")?,
                );
            }
            "--advertise-mix" => {
                advertise_mix = Some(args.next().ok_or("--advertise-mix requires host:port")?);
            }
            "--advertise-provider" => {
                advertise_provider = Some(
                    args.next()
                        .ok_or("--advertise-provider requires host:port")?,
                );
            }
            "--bootstrap" | "-b" => {
                bootstrap.push(args.next().ok_or("--bootstrap requires a node address")?);
            }
            "--help" | "-h" => {
                print_help();
                return Ok(());
            }
            other => return Err(format!("unknown argument: {other} (try --help)")),
        }
    }

    let storage = Storage::open(&data_dir).map_err(|e| e.to_string())?;
    let (secret, public) = load_or_create_identity(&data_dir)?;
    let listener = TcpListener::bind(&listen).map_err(|e| format!("cannot bind {listen}: {e}"))?;
    let shared = SharedStorage::new(storage);

    println!("Aegis relay — a blind server that stores sealed envelopes it cannot read.");
    println!("  listening on : {listen}");
    println!("  data dir     : {data_dir}");
    println!("  transport    : hybrid X25519 + ML-KEM-768 (post-quantum)");
    println!();
    println!("To defeat a first-connection MITM, pin this relay key on clients:");
    println!("  {}", hex(&public));

    println!();
    println!("This process holds no data keys; every byte it stores or serves is ciphertext.");

    let Some(mix_addr) = mix_listen else {
        println!();
        println!("Run with --mix <addr> to also serve as a mixnet node (recommended).");
        return serve(listener, shared, secret).map_err(|e| e.to_string());
    };

    // Node mode: serve the mailbox on a background thread, then bring up the mix
    // (which connects back to the mailbox over loopback), and park.
    let mailbox_thread = thread::spawn(move || serve(listener, shared, secret));
    start_mix_node(
        &data_dir,
        &listen,
        &mix_addr,
        advertise_mix,
        advertise_provider,
        &bootstrap,
    )?;
    // Block on the mailbox server; the mix + gossip run on their own threads.
    match mailbox_thread.join() {
        Ok(r) => r.map_err(|e| e.to_string()),
        Err(_) => Err("mailbox server thread panicked".into()),
    }
}

/// Bring up the mix + directory node alongside the mailbox: bind the mix
/// listener, learn the network from `bootstrap`, announce this node, and forward
/// + gossip on background threads. Deliveries go into the local mailbox.
fn start_mix_node(
    data_dir: &str,
    listen: &str,
    mix_listen: &str,
    advertise_mix: Option<String>,
    advertise_provider: Option<String>,
    bootstrap: &[String],
) -> Result<(), String> {
    let seed = load_or_create_mix_key(data_dir)?;
    let node = MixNode::from_seed(&seed);

    let mix_listener =
        TcpListener::bind(mix_listen).map_err(|e| format!("cannot bind mix {mix_listen}: {e}"))?;
    let mix_bound = mix_listener.local_addr().map_err(|e| e.to_string())?;

    // Addresses other nodes/clients use to reach us (public host, not 0.0.0.0).
    let mix_public: SocketAddr = advertise_mix
        .as_deref()
        .unwrap_or(mix_listen)
        .parse()
        .map_err(|_| "--advertise-mix must be host:port".to_string())?;
    let provider_public: SocketAddr = advertise_provider
        .as_deref()
        .unwrap_or(listen)
        .parse()
        .map_err(|_| "--advertise-provider must be host:port".to_string())?;

    let desc = NodeDescriptor::new(node.public_hop(), mix_public, Some(provider_public));

    // The mix stores deliveries in our own mailbox over loopback.
    let loopback = format!("127.0.0.1:{}", provider_public.port());
    // Ciphra needs the server up first; give it a moment.
    thread::sleep(Duration::from_millis(200));
    let mailbox = CiphraStore::connect(loopback.as_str(), None)
        .map_err(|e| format!("mix cannot reach local mailbox: {e}"))?;

    // Seed the directory with our own descriptor and START SERVING the mix port
    // BEFORE discovering peers. The bootstrap list can include our own address
    // (a lone seed node bootstraps from itself); if we discovered first, we'd
    // connect to our own not-yet-served mix port and block on the read forever,
    // so the mix service would never start and clients would hang on discovery.
    let directory = DirectoryState::new();
    directory.merge(std::slice::from_ref(&desc));

    println!();
    println!("Mix node — carries onion traffic and serves the directory.");
    println!("  mix listening: {mix_bound}");
    println!("  advertised   : mix {mix_public}  ·  provider {provider_public}");
    println!("  node id      : {}", hex(&desc.id));
    println!("  bootstrap    : {}", bootstrap.join(", "));

    let deliver = MailboxDeliver(Arc::new(Mutex::new(mailbox)));
    let service = MixService::new(node, directory.clone(), deliver);
    thread::spawn(move || {
        let _ = service.serve(mix_listener);
    });

    // Now that our own directory is being served, learn any peers (self-bootstrap
    // included) and merge them in.
    for b in bootstrap {
        match aegis_mix::discover(b.as_str()) {
            Ok(nodes) => directory.merge(&nodes),
            Err(e) => eprintln!("warning: bootstrap {b} unreachable: {e}"),
        }
    }

    aegis_mix::run_gossip(directory, desc, Duration::from_secs(30));
    Ok(())
}

/// Load or create the node's Sphinx mix key (X25519), persisted in `<data>/mix_key`.
fn load_or_create_mix_key(data_dir: &str) -> Result<[u8; 32], String> {
    let path = Path::new(data_dir).join(MIX_KEY_FILE);
    if path.exists() {
        std::fs::read(&path)
            .map_err(|e| e.to_string())?
            .try_into()
            .map_err(|_| format!("{MIX_KEY_FILE} is not a 32-byte key"))
    } else {
        let mut seed = [0u8; 32];
        aegis_crypto::fill_random(&mut seed);
        std::fs::write(&path, seed).map_err(|e| format!("cannot write {}: {e}", path.display()))?;
        Ok(seed)
    }
}

/// Load the relay's static transport key from `<data>/relay_key`, or create and
/// persist one on first run. Returns `(secret, public)`; only `public` is ever
/// shared (clients pin it).
fn load_or_create_identity(data_dir: &str) -> Result<([u8; 32], [u8; 32]), String> {
    let path = Path::new(data_dir).join(IDENTITY_FILE);
    let secret: [u8; 32] = if path.exists() {
        std::fs::read(&path)
            .map_err(|e| e.to_string())?
            .try_into()
            .map_err(|_| format!("{IDENTITY_FILE} is not a 32-byte key"))?
    } else {
        let secret = ServerIdentity::generate().secret_bytes();
        std::fs::write(&path, secret)
            .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
        secret
    };
    let public = ServerIdentity::from_secret(secret).public;
    Ok((secret, public))
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

fn print_help() {
    println!(
        "aegis-relay-server — run your own Aegis node (blind mailbox + mixnet)

USAGE:
    aegis-relay-server [--listen <ADDR>] [--data <DIR>]
    aegis-relay-server --mix <ADDR> --advertise-mix <HOST:PORT> \\
        --advertise-provider <HOST:PORT> [--bootstrap <ADDR>]...

OPTIONS:
    -l, --listen <ADDR>            Mailbox bind address (default: {DEFAULT_LISTEN})
    -d, --data <DIR>               Data directory (default: {DEFAULT_DATA_DIR})
    -m, --mix <ADDR>               Also run a mixnet node, binding this address
        --advertise-mix <H:P>      Public mix address others route to
        --advertise-provider <H:P> Public mailbox address clients poll
    -b, --bootstrap <ADDR>         A known node to learn the network from (repeatable)
    -h, --help                     Show this help

Without --mix it is a blind mailbox only. With --mix the same process is a full
node: it stores sealed envelopes it cannot read AND forwards onion traffic +
serves the gossiped directory, so clients auto-discover the network from it."
    );
}
