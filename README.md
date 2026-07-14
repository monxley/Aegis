# Aegis

**An anonymous, end-to-end-encrypted, post-quantum messenger built on the
[Ciphra](https://github.com/monxley/Ciphra) cryptographic core.**

Aegis is a Session-class messenger — no phone numbers, no central account — that
borrows Monero / CryptoNote *stealth addressing* for recipient unlinkability and
reuses Ciphra's blind, replicated server as a store-and-forward relay.

The design goal, in one line: **a message you cannot intercept, and if you do,
cannot read — and cannot tell who it was between.**

## Status

**Phase 0 — identity & stealth addressing — implemented.** The protocol is
specified first, so the code is an implementation of a *reviewed spec*.

- 📄 **[AEGIS_PROTOCOL.md](AEGIS_PROTOCOL.md)** — the full protocol design:
  identity & stealth addressing, PQXDH handshake, post-quantum Double Ratchet,
  blind store-and-forward delivery, and the onion-routing / mixnet layer.
- 🧮 **[docs/CRYPTO_MATH.md](docs/CRYPTO_MATH.md)** — the exact mathematics of
  every process: group operations, byte-precise KDF inputs, correctness proofs,
  and the security assumption each step rests on.
- 📦 **[crates/aegis-identity](crates/aegis-identity)** — Phase 0 crate:
  X25519 identities, shareable Aegis IDs, and DH-only stealth addressing, with
  zero third-party dependencies. `cargo test` runs the RFC/FIPS crypto vectors
  and the stealth-addressing correctness/unlinkability suite.

```console
$ cargo test
running 23 tests ... ok   # RFC 7748 / 5869 / 4231, NIST SHA-256, stealth + Aegis ID
```

### Roadmap

| Phase | Scope | Status |
|---|---|---|
| 0 | Identity, Aegis IDs, stealth addressing | ✅ implemented |
| 1 | PQXDH handshake + post-quantum Double Ratchet | ⏳ next |
| 2 | Blind store-and-forward delivery, sealed sender | ⏳ |
| 3 | Sphinx onion routing → Loopix mixnet | ⏳ |

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
