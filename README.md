# Aegis

**An anonymous, end-to-end-encrypted, post-quantum messenger built on the
[Ciphra](https://github.com/monxley/Ciphra) cryptographic core.**

Aegis is a Session-class messenger — no phone numbers, no central account — that
borrows Monero / CryptoNote *stealth addressing* for recipient unlinkability and
reuses Ciphra's blind, replicated server as a store-and-forward relay.

The design goal, in one line: **a message you cannot intercept, and if you do,
cannot read — and cannot tell who it was between.**

## Status

Pre-design. The protocol is being specified before any code is written, so the
implementation is an implementation of a *reviewed spec*, not an invented one.

- 📄 **[AEGIS_PROTOCOL.md](AEGIS_PROTOCOL.md)** — the full protocol design:
  identity & stealth addressing, PQXDH handshake, post-quantum Double Ratchet,
  blind store-and-forward delivery, and the onion-routing / mixnet layer.

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
