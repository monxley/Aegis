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

use std::net::TcpListener;
use std::path::Path;
use std::process::ExitCode;

use ciphra_crypto::ServerIdentity;
use ciphra_net::{serve, SharedStorage};
use ciphra_storage::Storage;

const DEFAULT_LISTEN: &str = "0.0.0.0:5077";
const DEFAULT_DATA_DIR: &str = "./aegis-relay-data";
const IDENTITY_FILE: &str = "relay_key";

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
    println!(
        "Clients connect with:  AegisApp::create_with_relay(seed, \"<host>:{}\")",
        listen.rsplit(':').next().unwrap_or("5077")
    );
    println!("To defeat a first-connection MITM, pin this relay key on clients:");
    println!("  {}", hex(&public));
    println!();
    println!("This process holds no data keys; every byte it stores or serves is ciphertext.");

    serve(listener, shared, secret).map_err(|e| e.to_string())
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
        "aegis-relay-server — run your own Aegis relay (a Ciphra blind server)

USAGE:
    aegis-relay-server [--listen <ADDR>] [--data <DIR>]

OPTIONS:
    -l, --listen <ADDR>   Address to bind (default: {DEFAULT_LISTEN})
    -d, --data <DIR>      Data directory (default: {DEFAULT_DATA_DIR})
    -h, --help            Show this help

The relay stores sealed Aegis envelopes it can neither read nor attribute.
Run it on any host both participants can reach, then point clients at it with
AegisApp::create_with_relay(seed, \"<host>:5077\")."
    );
}
