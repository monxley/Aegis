//! HMAC-SHA256 (RFC 2104) and HKDF-SHA256 (RFC 5869). Adapted from Ciphra's
//! `ciphra-crypto::hmac` (Apache-2.0). Verified against RFC test vectors.

use super::sha256::{sha256, Sha256};

const BLOCK_LEN: usize = 64;
pub const MAC_LEN: usize = 32;

/// HMAC-SHA256 with cached pad states.
#[derive(Clone)]
pub struct HmacSha256 {
    inner: Sha256,
    outer: Sha256,
}

impl HmacSha256 {
    pub fn new(key: &[u8]) -> Self {
        let mut key_block = [0u8; BLOCK_LEN];
        if key.len() > BLOCK_LEN {
            key_block[..MAC_LEN].copy_from_slice(&sha256(key));
        } else {
            key_block[..key.len()].copy_from_slice(key);
        }

        let mut ipad = [0x36u8; BLOCK_LEN];
        let mut opad = [0x5cu8; BLOCK_LEN];
        for i in 0..BLOCK_LEN {
            ipad[i] ^= key_block[i];
            opad[i] ^= key_block[i];
        }

        let mut inner = Sha256::new();
        inner.update(&ipad);
        let mut outer = Sha256::new();
        outer.update(&opad);
        HmacSha256 { inner, outer }
    }

    pub fn mac(&self, message: &[u8]) -> [u8; MAC_LEN] {
        let mut inner = self.inner.clone();
        inner.update(message);
        let mut outer = self.outer.clone();
        outer.update(&inner.finalize());
        outer.finalize()
    }
}

/// One-shot HMAC-SHA256.
pub fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; MAC_LEN] {
    HmacSha256::new(key).mac(message)
}

/// HKDF-SHA256 extract step: `PRK = HMAC(salt, ikm)`.
pub fn hkdf_extract(salt: &[u8], ikm: &[u8]) -> [u8; MAC_LEN] {
    hmac_sha256(salt, ikm)
}

/// HKDF-SHA256 expand step. `out.len()` must be at most `255 * 32`.
pub fn hkdf_expand(prk: &[u8; MAC_LEN], info: &[u8], out: &mut [u8]) {
    assert!(out.len() <= 255 * MAC_LEN, "HKDF output too long");
    let hmac = HmacSha256::new(prk);
    let mut t: Vec<u8> = Vec::with_capacity(MAC_LEN + info.len() + 1);
    let mut counter = 1u8;
    let mut written = 0usize;
    while written < out.len() {
        t.extend_from_slice(info);
        t.push(counter);
        let block = hmac.mac(&t);
        let take = (out.len() - written).min(MAC_LEN);
        out[written..written + take].copy_from_slice(&block[..take]);
        written += take;
        counter += 1;
        t.clear();
        t.extend_from_slice(&block);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::hex;

    #[test]
    fn hmac_rfc4231_vectors() {
        assert_eq!(
            hmac_sha256(&[0x0b; 20], b"Hi There").to_vec(),
            hex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
        );
        assert_eq!(
            hmac_sha256(b"Jefe", b"what do ya want for nothing?").to_vec(),
            hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        );
    }

    #[test]
    fn hkdf_rfc5869_case1() {
        let ikm = [0x0b; 22];
        let salt = hex("000102030405060708090a0b0c");
        let info = hex("f0f1f2f3f4f5f6f7f8f9");
        let prk = hkdf_extract(&salt, &ikm);
        assert_eq!(
            prk.to_vec(),
            hex("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")
        );
        let mut okm = [0u8; 42];
        hkdf_expand(&prk, &info, &mut okm);
        assert_eq!(
            okm.to_vec(),
            hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
        );
    }
}
