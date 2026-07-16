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

const VAULT_VERSION: u8 = 1;
const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;
/// PBKDF2 rounds. High enough to make an offline guess against a stolen device
/// slow (a fraction of a second per try on a phone), low enough to unlock
/// promptly. The random per-vault salt already defeats any precomputation.
const ITERATIONS: u32 = 120_000;
const AAD: &[u8] = b"aegis-seed-vault-v1";

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
    if blob.len() < min || blob[0] != VAULT_VERSION {
        return None;
    }
    let salt = &blob[1..1 + SALT_LEN];
    let nonce: [u8; NONCE_LEN] = blob[1 + SALT_LEN..1 + SALT_LEN + NONCE_LEN]
        .try_into()
        .ok()?;
    let sealed = &blob[1 + SALT_LEN + NONCE_LEN..];
    let mut key = [0u8; 32];
    aegis_crypto::pbkdf2_sha256(password.as_bytes(), salt, ITERATIONS, &mut key);
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
}
