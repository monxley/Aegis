//! # aegis-crypto — zero-dependency cryptographic primitives
//!
//! Every primitive Aegis needs, implemented from the primary specifications
//! and verified in-tree against official RFC/FIPS test vectors. There are no
//! third-party dependencies: the supply chain is the Rust standard library
//! and this crate (mirroring Ciphra's ADR-0002).
//!
//! These files are adapted from Ciphra's `ciphra-crypto` (Apache-2.0, same
//! authors); they live here rather than as a dependency because
//! `ciphra-crypto` does not export the modules Aegis needs (`x25519`,
//! `ml_kem`) and this build environment blocks the crates.io registry.
//!
//! | Module | Primitive | Spec | Aegis use |
//! |---|---|---|---|
//! | [`x25519`] | X25519 Diffie–Hellman | RFC 7748 | stealth addr, PQXDH, ratchet |
//! | [`ml_kem`] | ML-KEM-768 KEM | FIPS 203 | post-quantum handshake/ratchet |
//! | [`aead`] | ChaCha20-Poly1305 | RFC 8439 | message encryption |
//! | [`chacha20`] / [`poly1305`] | AEAD internals | RFC 8439 | (used by `aead`) |
//! | [`keccak`] | SHA-3 / SHAKE | FIPS 202 | (used by `ml_kem`) |
//! | [`sha256`] | SHA-256 | FIPS 180-4 | Aegis IDs, KDF |
//! | [`hmac`] | HMAC / HKDF | RFC 2104 / 5869 | all key derivation |
//! | [`rand`] | OS CSPRNG | — | key generation |

pub mod aead;
pub mod chacha20;
pub mod hmac;
pub mod keccak;
pub mod ml_kem;
pub mod poly1305;
pub mod rand;
pub mod sha256;
pub mod x25519;
pub(crate) mod zeroize;

pub use hmac::{hkdf_expand, hkdf_extract, hmac_sha256, MAC_LEN};
pub use rand::fill_random;
pub use sha256::{sha256, Sha256};

#[cfg(test)]
pub(crate) mod test_util {
    /// Decode a hex string; test helper only.
    pub fn hex(s: &str) -> Vec<u8> {
        let s: String = s.chars().filter(|c| !c.is_whitespace()).collect();
        assert!(s.len().is_multiple_of(2), "odd-length hex string");
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("bad hex"))
            .collect()
    }
}
