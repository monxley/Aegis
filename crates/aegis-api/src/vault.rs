//! Password vault for the master seed at rest.
//!
//! The app lock is only meaningful if bypassing the *screen* buys nothing — so
//! the seed itself is encrypted under a key derived from the password, and the
//! plaintext seed is never stored. Without the password there is no seed, so the
//! engine (and thus every API call) cannot be constructed at all: the lock is on
//! the data, not just the UI.
//!
//! Construction: `key = PBKDF2-HMAC-SHA256(password, salt, N)`, then
//! `ChaCha20-Poly1305` over the seed. The blob is
//! `version ‖ salt ‖ nonce ‖ sealed` and is safe to persist on the device.

use aegis_crypto::aead;

/// Current vault version: PBKDF2 at [`ITERATIONS`]. New seals always use this.
const VAULT_VERSION: u8 = 2;
const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;
/// PBKDF2 rounds for new vaults — the OWASP-2023 floor for PBKDF2-HMAC-SHA256.
/// PBKDF2 is not memory-hard, so a memory-hard KDF (Argon2id) is the real fix
/// for the seized-device threat and is tracked in the roadmap; this raises the
/// offline-guess cost meaningfully in the meantime. The random per-vault salt
/// already defeats precomputation.
const ITERATIONS: u32 = 600_000;
/// Iterations used by v1 blobs from older builds. Kept so an existing vault
/// still opens; it is upgraded to the current version whenever it is re-sealed
/// (set/change password).
const ITERATIONS_V1: u32 = 120_000;
const AAD: &[u8] = b"aegis-seed-vault-v1";

/// PBKDF2 iterations to use for a blob of the given version, or `None` if the
/// version is unknown.
fn iterations_for(version: u8) -> Option<u32> {
    match version {
        1 => Some(ITERATIONS_V1),
        2 => Some(ITERATIONS),
        _ => None,
    }
}

/// Encrypt `secret` under `password`. Output is self-describing and persistable.
pub fn seal_secret(password: &str, secret: &[u8]) -> Vec<u8> {
    let mut salt = [0u8; SALT_LEN];
    let mut nonce = [0u8; NONCE_LEN];
    aegis_crypto::fill_random(&mut salt);
    aegis_crypto::fill_random(&mut nonce);
    let mut key = [0u8; 32];
    aegis_crypto::pbkdf2_sha256(password.as_bytes(), &salt, ITERATIONS, &mut key);
    let sealed = aead::seal(&key, &nonce, secret, AAD);
    let mut out = Vec::with_capacity(1 + SALT_LEN + NONCE_LEN + sealed.len());
    out.push(VAULT_VERSION);
    out.extend_from_slice(&salt);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&sealed);
    out
}

/// Recover the secret sealed by [`seal_secret`]. Returns `None` on a wrong
/// password or a malformed blob — the two are indistinguishable, so a caller
/// gets no oracle beyond "unlocked or not".
pub fn open_secret(password: &str, blob: &[u8]) -> Option<Vec<u8>> {
    let min = 1 + SALT_LEN + NONCE_LEN + TAG_LEN;
    if blob.len() < min {
        return None;
    }
    let iterations = iterations_for(blob[0])?;
    let salt = &blob[1..1 + SALT_LEN];
    let nonce: [u8; NONCE_LEN] = blob[1 + SALT_LEN..1 + SALT_LEN + NONCE_LEN]
        .try_into()
        .ok()?;
    let sealed = &blob[1 + SALT_LEN + NONCE_LEN..];
    let mut key = [0u8; 32];
    aegis_crypto::pbkdf2_sha256(password.as_bytes(), salt, iterations, &mut key);
    aead::open(&key, &nonce, sealed, AAD)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_wrong_password() {
        let seed = vec![7u8; 32];
        let blob = seal_secret("correct horse battery staple", &seed);
        assert_ne!(&blob[1 + SALT_LEN + NONCE_LEN..], &seed[..]); // encrypted
        assert_eq!(
            open_secret("correct horse battery staple", &blob).as_deref(),
            Some(&seed[..])
        );
        assert!(open_secret("wrong password", &blob).is_none());
        assert!(open_secret("", &blob).is_none());
        // Two seals of the same secret differ (random salt+nonce).
        assert_ne!(seal_secret("pw", &seed), seal_secret("pw", &seed));
    }

    #[test]
    fn new_seals_use_current_version() {
        assert_eq!(seal_secret("pw", &[1u8; 32])[0], VAULT_VERSION);
    }

    #[test]
    fn legacy_v1_blob_still_opens() {
        // Hand-build a v1 blob (PBKDF2 at the old iteration count) and confirm
        // the version-aware open still recovers it.
        let seed = vec![9u8; 32];
        let salt = [3u8; SALT_LEN];
        let nonce = [4u8; NONCE_LEN];
        let mut key = [0u8; 32];
        aegis_crypto::pbkdf2_sha256(b"legacy", &salt, ITERATIONS_V1, &mut key);
        let sealed = aead::seal(&key, &nonce, &seed, AAD);
        let mut blob = vec![1u8]; // version 1
        blob.extend_from_slice(&salt);
        blob.extend_from_slice(&nonce);
        blob.extend_from_slice(&sealed);
        assert_eq!(open_secret("legacy", &blob).as_deref(), Some(&seed[..]));
        assert!(open_secret("wrong", &blob).is_none());
    }
}
