# Aegis

**An anonymous, end-to-end-encrypted, post-quantum messenger built on the
[Ciphra](https://github.com/monxley/Ciphra) cryptographic core.**

Aegis is a Session-class messenger — no phone numbers, no central account — that
borrows Monero / CryptoNote *stealth addressing* for recipient unlinkability and
reuses Ciphra's blind, replicated server as a store-and-forward relay.

The design goal, in one line: **a message you cannot intercept, and if you do,
cannot read — and cannot tell who it was between.**

## Status

**Phases 0–3.5 implemented:** identity & stealth addressing, the post-quantum
session core (PQXDH handshake + Double Ratchet), ML-DSA-65 prekey-bundle
signing (authenticity), an ongoing post-quantum ratchet, blind store-and-forward
delivery with sealed-sender envelopes, **Sphinx onion routing**, and **Loopix**
mixing + cover traffic — completing the network-anonymity layer. The protocol is
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
aegis-net     : 15 ok   # Sphinx onion routing + Loopix Poisson mixing & cover traffic
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
    └── aegis-net/           # Phases 3–3.5 — Layer 4b
        └── src/             #   lib.rs (Sphinx) · loopix.rs (Poisson mix + cover) · rng.rs
```

Dependency flow: every `aegis-*` crate builds on `aegis-crypto`; nothing
depends on a third-party crate.

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

All five protocol layers now have a working, tested implementation. What remains
is hardening and integration, not new layers: an external security audit (a
release blocker, as for Ciphra), payload non-malleability (LIONESS), the SPQR
KEM-chunking size optimization, wiring `MailboxStore` to a live Ciphra blind
server, and folding the identity/session/mailbox keys into one client type.

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
