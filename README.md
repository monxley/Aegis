# Aegis

**An anonymous, end-to-end-encrypted, post-quantum messenger built on the
[Ciphra](https://github.com/monxley/Ciphra) cryptographic core.**

Aegis is a Session-class messenger — no phone numbers, no central account — that
borrows Monero / CryptoNote *stealth addressing* for recipient unlinkability and
reuses Ciphra's blind, replicated server as a store-and-forward relay.

The design goal, in one line: **a message you cannot intercept, and if you do,
cannot read — and cannot tell who it was between.**

## Status

**All five protocol layers are implemented, and folded into one client.** Under
the hood: identity & stealth addressing, the post-quantum session core (PQXDH
handshake + Double Ratchet), ML-DSA-65 prekey-bundle signing (authenticity), an
ongoing post-quantum ratchet, blind store-and-forward delivery with sealed-sender
envelopes, **Sphinx onion routing** with a non-malleable **LIONESS** payload, and
**Loopix** mixing + cover traffic. `AegisClient` ties them into one messenger API,
and it runs over a **live Ciphra blind server** (`aegis-relay`). `aegis-api`
wraps it into a UI-facing engine (identity, contacts, chat history), and a
**Flutter app** (`app/`) drives that engine over `flutter_rust_bridge` —
Android-first, Linux next. The protocol is specified first, so the code is an
implementation of a *reviewed spec*.

- 📄 **[AEGIS_PROTOCOL.md](AEGIS_PROTOCOL.md)** — the full protocol design:
  identity & stealth addressing, PQXDH handshake, post-quantum Double Ratchet,
  blind store-and-forward delivery, and the onion-routing / mixnet layer.
- 🧮 **[docs/CRYPTO_MATH.md](docs/CRYPTO_MATH.md)** — the exact mathematics of
  every process: group operations, byte-precise KDF inputs, correctness proofs,
  and the security assumption each step rests on.

```console
$ cargo test --all
aegis-crypto  : 36 ok   # RFC 7748/8439/5869/4231, FIPS 180-4/202/203/204, ML-KEM + ML-DSA
aegis-identity: 19 ok   # stealth addressing, identity signing, Aegis ID key binding
aegis-session : 24 ok   # PQXDH, Double Ratchet, PQ ratchet, signed bundles, e2e authenticity
aegis-mailbox : 10 ok   # sealed-sender envelopes, blind relay, full-stack message delivery
aegis-net     : 23 ok   # Sphinx (LIONESS payload) + Loopix Poisson mixing & cover traffic
aegis-relay   :  2 ok   # a full conversation over a live in-process Ciphra blind server
aegis-mix     :  8 ok   # networked mix nodes, gossiped directory, MixnetStore, SURB receive
aegis-client  : 11 ok   # one-identity messenger: conversations, multi-peer, MITM rejection
aegis-api     :  9 ok   # UI engine + mixnet end-to-end + sent/delivered/read receipts
```

The **Flutter app** (`app/`) is the interface on top of `aegis-api`; see
[app/README.md](app/README.md) for the build.

## Quick start

`AegisClient` is the whole messenger behind one type — one identity backs the
shareable Aegis ID, the view key, the handshake key, and the signing key; PQXDH
sessions and the Double Ratchet are established and reused automatically; every
message goes out as a sealed-sender envelope over a blind relay.

```rust
use aegis_client::AegisClient;
use aegis_mailbox::InMemoryStore;

let mut alice = AegisClient::generate();
let mut bob   = AegisClient::generate();
let mut relay = InMemoryStore::new();          // a blind store-and-forward relay

// Alice starts a conversation from Bob's published Aegis ID + prekey bundle.
alice.start_conversation(&mut relay, &bob.aegis_id(), &bob.bundle(), b"hi bob").unwrap();

// Bob scans the relay (which learns neither who it is for nor from) and reads it.
let inbox = bob.receive(&relay);
assert_eq!(inbox[0].message, b"hi bob");

// Bob replies on the now-established session; Alice reads it.
bob.send(&mut relay, &inbox[0].from, b"hi alice").unwrap();
assert_eq!(alice.receive(&relay)[0].message, b"hi alice");
```

### Project map

```
Aegis/
├── AEGIS_PROTOCOL.md        # protocol design (all 5 layers)
├── docs/CRYPTO_MATH.md      # exact mathematics + security assumptions
└── crates/
    ├── aegis-crypto/        # zero-dep primitives, RFC/FIPS test-vector verified
    │   └── src/             #   x25519 · ml_kem · ml_dsa · aead(chacha20+poly1305)
    │                        #   keccak · sha256 · hmac/hkdf · rand
    ├── aegis-identity/      # Phase 0 — Layer 1
    │   └── src/             #   identity.rs (keys, signing, Aegis ID) · stealth.rs
    ├── aegis-session/       # Phases 1–1.6 — Layers 2–3
    │   └── src/             #   bundle.rs (signed prekeys) · pqxdh.rs · ratchet.rs (PQ)
    ├── aegis-mailbox/       # Phase 2 — Layer 4a
    │   └── src/             #   sealed-sender envelopes over a blind store-and-forward relay
    ├── aegis-net/           # Phases 3–3.5 — Layer 4b
    │   └── src/             #   lib.rs (Sphinx + LIONESS) · loopix.rs (mix + cover) · rng.rs
    ├── aegis-relay/         # CiphraStore: MailboxStore over a live Ciphra blind server
    │   └── src/             #   lib.rs (CiphraStore) · tests/ (live in-process server)
    ├── aegis-relay-server/  # `aegis-relay-server` binary: run your own blind relay
    │   └── src/             #   main.rs (persistent, pinnable Ciphra blind server)
    ├── aegis-mix/           # the mixnet: networked Sphinx mix nodes + MixnetStore
    │   └── src/             #   MixService (forward/deliver) · MixnetStore (onion send)
    ├── aegis-client/        # the messenger: one identity, one API over all layers
    │   └── src/             #   lib.rs (AegisClient) · wire.rs (envelope inner format)
    └── aegis-api/           # UI-facing engine (AegisApp): identity, contacts, chat, poll
        └── src/             #   lib.rs (AegisApp) · wire.rs (prekey-bundle byte format)

app/                         # Flutter interface (Android-first, Linux next)
├── rust/                    #   flutter_rust_bridge crate wrapping aegis-api
└── lib/                     #   Dart UI: theme, engine wrapper, screens
```

Dependency flow: every `aegis-*` crate builds on `aegis-crypto`; `aegis-client`
sits on identity + session + mailbox. The only outside dependency is
`aegis-relay` → Ciphra's `ciphra-net` (the companion project, reached as a git
dependency) for the live blind-server client — still nothing from crates.io.

### Roadmap

| Phase | Scope | Status |
|---|---|---|
| 0 | Identity, Aegis IDs, stealth addressing | ✅ implemented |
| 1 | PQXDH handshake + post-quantum Double Ratchet | ✅ implemented |
| 1.5 | ML-DSA-65 prekey-bundle signing, Aegis ID key binding (authenticity, G8) | ✅ implemented |
| 1.6 | Ongoing PQ ratchet — ML-KEM re-encapsulation into the root KDF (§4) | ✅ implemented |
| 2 | Blind store-and-forward delivery, sealed sender | ✅ implemented |
| 3 | Sphinx onion routing (fixed-size layered packets) | ✅ implemented |
| 3.5 | Loopix mixing — Poisson delays + cover traffic (§6.2) | ✅ implemented |
| — | Hardening: non-malleable LIONESS onion payload (anti-tagging) | ✅ implemented |
| — | `aegis-relay`: `MailboxStore` over a live Ciphra blind server | ✅ implemented |
| — | `AegisClient`: one-identity messenger API over all layers | ✅ implemented |
| — | `aegis-api` + Flutter app: UI engine and Android/Linux interface | ✅ implemented |
| — | `aegis-relay-server`: run your own blind relay (persistent, pinnable) | ✅ implemented |
| — | Session persistence: sessions, contacts & history survive a restart | ✅ implemented |
| — | `aegis-mix`: networked Sphinx mixnet + onion-routed send path (`MixnetStore`) | ✅ implemented |
| — | Node auto-discovery: gossiped directory, clients bootstrap onto the net | ✅ implemented |
| — | `AegisApp::create_on_network`: zero-setup, auto-discover + route over mixnet | ✅ implemented |
| — | Opt-in node: any client can also be a mix forwarder (in-app toggle) | ✅ implemented |
| — | Loopix mix delays + client cover traffic | ✅ implemented |
| — | Cross-provider mail sharding (recipient's provider from its view key) | ✅ implemented |
| — | Turnkey full node (`--mix`) + Docker/systemd deploy + Flutter CI | ✅ implemented |
| — | Sphinx reply blocks (SURBs): create / wrap / recover primitive | ✅ implemented |
| — | Receive-path anonymity: SURB poll-through-mixnet protocol | ✅ implemented |
| — | Anonymous receive in the app (`create_on_network_with_receive`, node mode) | ✅ implemented |
| — | Proof-of-work node admission (Sybil resistance, no stake/money) | ✅ implemented |
| — | Message-length padding to buckets (hide length from traffic analysis) | ✅ implemented |
| — | Safety numbers (SAS) — human-verifiable MITM detection | ✅ implemented |
| — | Poisson cover traffic from the app on the mixnet | ✅ implemented |
| — | Console VPS deploy (`deploy/install.sh`): zero-config headless node | ✅ implemented |
| — | Console APK build (`deploy/build-apk.sh`): rootless, from a phone + VPS | ✅ implemented |
| — | Delivery & read receipts (sent · delivered · read), inside the ratchet | ✅ implemented |
| — | Self-healing mailbox connection (survives dropped / half-open mobile links) | ✅ implemented |
| — | In-app profile & identity reset; connection status, message times in the UI | ✅ implemented |
| — | App-lock password: master seed encrypted at rest (PBKDF2 + ChaCha20-Poly1305) | ✅ implemented |
| — | Network nodes view: browse the gossiped directory, star preferred nodes | ✅ implemented |
| — | Opt-in new-message notifications (content-free, privacy-preserving) | ✅ implemented |
| — | Self-cleaning mailbox: node TTL sweep so it can't fill the disk | ✅ implemented |
| — | Node mode gate: reject local IPs, 20-min verify, online/offline node list | ✅ implemented |
| — | 24-word recovery phrase: back up & restore the identity | ✅ implemented |
| — | Disappearing messages: per-chat timer, synced, auto-pruned both sides | ✅ implemented |
| — | Screenshot / screen-recording block (Android `FLAG_SECURE`, on by default, toggleable) | ✅ implemented |
| — | Resilient send: local copy is kept and auto-retried if delivery fails (never lost) | ✅ implemented |
| — | Duress / decoy password: a second password opens an empty decoy account | ✅ implemented |
| — | Panic wipe: hold-to-confirm instant erase, from the lock screen or Settings | ✅ implemented |
| — | Biometric unlock: fingerprint / face over the app password (keystore-held key) | ✅ implemented |

All five protocol layers have a working, tested implementation with a
non-malleable **LIONESS** onion payload; `AegisClient` unifies them into one
messenger, and `aegis-relay` runs a full conversation over a **live Ciphra blind
server** (an in-process `ciphra-server` in the test). On top, `aegis-api` exposes
a UI-facing engine and a **Flutter app** (`app/`) provides the interface.
Conversations **survive a restart**: `AegisApp` serializes its sessions (the
Double Ratchet, including skipped-message keys), contacts, and history, and the
app restores them on launch. The **mixnet** (`aegis-mix`) turns `aegis-net`'s
Sphinx routing into a networked layer: `MixnetStore` onion-routes each send
through a random path of mix nodes to a provider, so no single node links the
sender to the deposited message. Messages carry **delivery & read receipts**
(sent · delivered · read), riding inside the Double Ratchet so the network sees
only sealed envelopes, and the mailbox connection is **self-healing** — it
reconnects through a dropped or half-open mobile link, so receiving survives a
network change. Sending is resilient too: the local copy is stored **first,
unconditionally**, so a message never vanishes on a transient relay failure —
it is marked *failed* and **auto-retried** on the next poll (and can be tapped
to retry). The app also hardens against physical coercion: the screen is
**FLAG_SECURE** by default (no screenshots or screen recording, blank in the app
switcher; toggleable in Settings), a **duress password** opens an empty decoy account instead of the
real one — which stays encrypted and hidden — and a **panic wipe** (hold to
confirm) erases everything from the lock screen or Settings. What remains is
hardening, not new layers: an external security
audit (a release blocker, as for Ciphra), the SPQR KEM-chunking size
optimization, group messaging, and app polish (push wake-ups so mail arrives
without the app open). Note: a scannable QR is **not** on the list — a
post-quantum share code (ML-KEM + ML-DSA bundle) is ~8 KB, far past a QR's
~3 KB ceiling, so identities are shared by copyable code.

**Who runs the nodes.** End users run nothing — a fresh install calls
`create_on_network`, **auto-discovers** the node set from a bootstrap address
(the directory gossips between nodes, so it stays current without a new build),
and routes over the mixnet. The node layer is **opt-in**: any client *can* also
be a mix forwarder (a Settings toggle, on by default on always-on desktop/Linux,
off + constrained on battery-powered Android), so the network is powered by
volunteers, not forced onto every phone. This keeps a stable, less Sybil-prone
node set — the same reason Session, Tor, and Nym use vetted/staked nodes rather
than "every phone is a relay".

Mail is **sharded across providers**: a message is onion-routed to the provider
its recipient polls, chosen deterministically from the recipient's view key, so
no node learns the pairing. A full node (blind mailbox + mix + directory) is one
command — `aegis-relay-server --mix` (see [`deploy/`](deploy/) for Docker /
systemd) — and CI compiles both the Rust workspace and the Flutter app on every
push.

**Receive-path anonymity** is implemented on the Sphinx **reply-block (SURB)**
primitive (`Surb::create` / `SurbHeader::wrap` / `Surb::recover`, with a distinct
`SURB_MARKER` exit that returns the reply still onion-wrapped for the creator to
peel). A recipient issues SURBs routed back to its own node and onion-routes a
fetch request to its provider; the provider answers each with an envelope routed
back through a SURB, so it **never learns who is asking** (`aegis-mix` proves the
whole flow end to end in a test: the recipient recovers and opens its mail with
its view key). `AegisApp::create_on_network_with_receive` wires it into the app:
on a reachable device with node mode on, the app runs its own node and polls
through the mixnet, so the provider never learns who is polling (an integration
test drives two apps end to end). This needs the recipient reachable, so it pairs
with node mode; NATed phones keep the direct poll until a bidirectional
poll-through-mixnet circuit lands.

## Build & run it yourself

Aegis is two things: a **Rust core** (the crypto + protocol, buildable anywhere
Rust runs) and a **Flutter app** on top of it. You can exercise the core from a
terminal in seconds; the app needs the Flutter toolchain.

### 1. The core, in a terminal

Only [Rust](https://rustup.rs) (stable) is required — nothing from crates.io; the
one external dependency (Ciphra) is fetched as a git dependency.

```sh
git clone https://github.com/monxley/Aegis
cd Aegis

cargo test --all        # run every layer's test vectors + end-to-end tests
cargo build --release    # build all crates
```

That builds and verifies the whole protocol (identity, PQXDH, ratchet, mailbox,
Sphinx/Loopix, the live-relay integration). The `## Quick start` snippet above is
a runnable program: drop it into `fn main()` of a crate that depends on
`aegis-client` + `aegis-mailbox`.

### 2. Run your own relay

To message someone on another network you need a **relay both of you can
reach** — a Ciphra blind server that stores sealed envelopes it can neither read
nor attribute. `aegis-relay-server` is that, turnkey:

```sh
# On a host with a public IP / forwarded port (a VPS, a home server):
cargo run -p aegis-relay-server --release -- --listen 0.0.0.0:5077 --data /var/lib/aegis-relay
```

On first run it creates a persistent transport identity in `<data>/relay_key`
and prints its **public key** — clients can pin that to defeat a
first-connection MITM. Restarting keeps the same key and all stored envelopes.
The process holds no data keys; everything it stores or serves is ciphertext.

Then both participants point their client at it:

```rust
let mut me = aegis_api::AegisApp::create_with_relay(seed, "relay.example:5077".into())?;
```

In the app, put `relay.example:5077` in the **relay** field on first launch.
Both sides must use the **same** relay; a message is stored there until the
recipient polls for it.

### 3. The app, on your phone (Android)

**One-command build, no desktop.** If all you have is a phone and a VPS, build
the APK on the VPS entirely from the console — it installs a JDK, Flutter, the
Android SDK/NDK, and Rust **under `$HOME` with no root**, generates the bindings,
cross-compiles the engine, and emits an installable APK:

```sh
curl -fsSL https://raw.githubusercontent.com/monxley/Aegis/main/deploy/build-apk.sh | bash
```

and stand up a node just as headlessly (`deploy/install.sh`, see step 2). The
manual toolchain path below is for a desktop with Flutter already set up.

**Prerequisites**, once:

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (3.3+) and the
  Android SDK + NDK (installed via Android Studio, or `sdkmanager`).
- Rust with the Android targets and the bridge tooling:

  ```sh
  rustup target add aarch64-linux-android armv7-linux-androideabi \
                    x86_64-linux-android i686-linux-android
  cargo install flutter_rust_bridge_codegen cargo-ndk
  ```

**Build & run** (from the repo root):

```sh
cd app

# 1. Scaffold the platform folders the first time (android/, linux/ …).
flutter create --platforms=android,linux .

# 2. Generate the Dart↔Rust bindings from aegis-api (writes lib/src/rust/).
flutter_rust_bridge_codegen generate

# 3. Compile the Rust engine for Android into the app's jniLibs.
cd rust
cargo ndk -o ../android/app/src/main/jniLibs build --release
cd ..

# 4. Plug in a phone (USB debugging on) or start an emulator, then:
flutter devices        # confirm your phone is listed
flutter run --release  # builds the APK, installs it, and launches Aegis
```

To leave an installed APK you can sideload later:

```sh
flutter build apk --release
# → build/app/outputs/flutter-apk/app-release.apk
```

**Linux desktop** (same engine, no Android tooling needed):

```sh
cd app
flutter create --platforms=linux .     # first time only
flutter_rust_bridge_codegen generate
flutter run -d linux
```

On first launch the app mints an identity locally (no phone number, no email)
and joins the anonymous mixnet with zero setup (an **Advanced** sheet offers a
specific relay or an offline mode). Share your code from **Settings → Your
profile** (or the identity screen) and add a contact by pasting theirs; sent
messages show **sent · delivered · read** ticks. See
[app/README.md](app/README.md) for the architecture.

## Design in brief

| Layer | Protocol (published, not invented) | Property |
|---|---|---|
| Identity | CryptoNote-style stealth addressing (DH-only) | recipient anonymity |
| Handshake | PQXDH (X25519 + ML-KEM-768) | post-quantum key agreement |
| Conversation | Post-quantum Double Ratchet | forward & post-compromise secrecy |
| Delivery | Ciphra blind server + sealed sender | sender anonymity, no plaintext |
| Network | Sphinx onion routing → Loopix mixnet | traffic-analysis resistance |

Every cryptographic *primitive* Aegis needs (ChaCha20-Poly1305, X25519,
ML-KEM-768, ML-DSA-65, HKDF/HMAC/SHA-3) already exists and is test-vector-verified
in Ciphra. Aegis is protocol-assembly on top of that core.

## Guiding rule

**Implement, don't invent.** Aegis writes well-studied protocols from scratch on
Ciphra's primitives. It does not design new cryptography. See
[AEGIS_PROTOCOL.md §1](AEGIS_PROTOCOL.md).

## License

[Apache-2.0](LICENSE)

## Support Aegis

Aegis is free, open, and built to keep private conversations private. If it's
worth something to you, a donation funds the work — especially the external
security audit that stands between the code and a real release.

- **BTC** — `bc1qlakzxqgaahuqf7newzfc4dfnhk4knnm4pht6q3`
- **ETH** — `0x6be4c971f7c7e765ab92a9f1eed4098ffdf77805`

Thank you. 🛡️
