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
and it runs over a **live Ciphra blind server** (`aegis-relay`). The protocol is
specified first, so the code is an implementation of a *reviewed spec*.

- 📄 **[AEGIS_PROTOCOL.md](AEGIS_PROTOCOL.md)** — the full protocol design:
  identity & stealth addressing, PQXDH handshake, post-quantum Double Ratchet,
  blind store-and-forward delivery, and the onion-routing / mixnet layer.
- 🧮 **[docs/CRYPTO_MATH.md](docs/CRYPTO_MATH.md)** — the exact mathematics of
  every process: group operations, byte-precise KDF inputs, correctness proofs,
  and the security assumption each step rests on.

```console
$ cargo test --all
aegis-crypto  : 36 ok   # RFC 7748/8439/5869/4231, FIPS 180-4/202/203/204, ML-KEM + ML-DSA
aegis-identity: 17 ok   # stealth addressing, identity signing, Aegis ID key binding
aegis-session : 20 ok   # PQXDH, Double Ratchet, PQ ratchet, signed bundles, e2e authenticity
aegis-mailbox : 10 ok   # sealed-sender envelopes, blind relay, full-stack message delivery
aegis-net     : 16 ok   # Sphinx (LIONESS payload) + Loopix Poisson mixing & cover traffic
aegis-relay   :  2 ok   # a full conversation over a live in-process Ciphra blind server
aegis-client  :  7 ok   # one-identity messenger: conversations, multi-peer, MITM rejection
```

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
    └── aegis-client/        # the messenger: one identity, one API over all layers
        └── src/             #   lib.rs (AegisClient) · wire.rs (envelope inner format)
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

All five protocol layers have a working, tested implementation with a
non-malleable **LIONESS** onion payload; `AegisClient` unifies them into one
messenger, and `aegis-relay` runs a full conversation over a **live Ciphra blind
server** (an in-process `ciphra-server` in the test). What remains is hardening,
not new layers: an external security audit (a release blocker, as for Ciphra),
the SPQR KEM-chunking size optimization, and group messaging.

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
