//! Aegis cryptographic primitives — zero third-party dependencies.
//!
//! These primitives are adapted from the Ciphra project's `ciphra-crypto`
//! crate (Apache-2.0, same authors), implemented from the primary
//! specifications and verified against official RFC/FIPS test vectors:
//! SHA-256 (FIPS 180-4), HMAC/HKDF (RFC 2104 / 5869) and X25519 (RFC 7748).
//!
//! They live here rather than as a dependency because `ciphra-crypto` does
//! not currently export its `x25519` module publicly, and this build
//! environment blocks the crates.io registry (Ciphra ADR-0002). Once
//! `ciphra-crypto` exposes the primitives Aegis needs, this module becomes a
//! thin re-export seam — see `docs/adr` (planned).

pub mod hmac;
pub mod rand;
pub mod sha256;
pub mod x25519;
pub(crate) mod zeroize;

pub use hmac::{hkdf_expand, hkdf_extract};
pub use rand::fill_random;
pub use sha256::sha256;

#[cfg(test)]
pub(crate) fn hex(s: &str) -> Vec<u8> {
    let s: String = s.chars().filter(|c| !c.is_whitespace()).collect();
    assert!(s.len().is_multiple_of(2), "odd-length hex string");
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("bad hex"))
        .collect()
}
