//! The Double Ratchet (see `docs/CRYPTO_MATH.md` §3): a symmetric-key ratchet
//! gives every message a unique key (forward secrecy, G2), and a DH ratchet
//! folds fresh entropy into the root on every round trip (post-compromise
//! security, G3). Message encryption is ChaCha20-Poly1305 with the header
//! bound in as associated data.
//!
//! Phase 1 implements the classical (X25519) Double Ratchet seeded by the
//! post-quantum PQXDH secret. The *ongoing* PQ ratchet — mixing an ML-KEM
//! re-encapsulation into the root KDF (§4) — is the planned hardening on top.

use std::collections::HashMap;

use aegis_crypto::x25519::SecretKey;
use aegis_crypto::{aead, fill_random, hkdf_expand, hkdf_extract, hmac_sha256};

const MAX_SKIP: u32 = 1000;
/// Header layout: ratchet public key (32) ‖ prev-chain length (4 LE) ‖ N (4 LE).
const HEADER_LEN: usize = 32 + 4 + 4;
const ROOT_INFO: &[u8] = b"aegis/ratchet/root";
const MSG_INFO: &[u8] = b"aegis/ratchet/msg";

/// An encrypted Double Ratchet message: cleartext header + AEAD ciphertext.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Message {
    /// `dh_pub ‖ prev_n ‖ n` — authenticated (as AAD) but not encrypted.
    pub header: [u8; HEADER_LEN],
    /// ChaCha20-Poly1305 sealed payload (ciphertext ‖ tag).
    pub ciphertext: Vec<u8>,
}

/// Errors from ratchet operations.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum RatchetError {
    /// The message asked us to skip more than `MAX_SKIP` keys — refused so a
    /// malicious header cannot force unbounded work.
    TooManySkipped,
    /// AEAD verification failed: wrong key, tampered ciphertext/header, or a
    /// mismatched associated data.
    DecryptFailed,
    /// This ratchet has not yet received a message, so it cannot send (the
    /// responder must receive the initiator's first message first).
    NotInitializedForSending,
}

// --- key-derivation functions (§3.1) -------------------------------------

/// KDF_RK: HKDF(salt=RK, ikm=dh_out, "aegis/ratchet/root", 64) → (RK', CK).
fn kdf_rk(root_key: &[u8; 32], dh_out: &[u8; 32]) -> ([u8; 32], [u8; 32]) {
    let prk = hkdf_extract(root_key, dh_out);
    let mut out = [0u8; 64];
    hkdf_expand(&prk, ROOT_INFO, &mut out);
    let mut new_root = [0u8; 32];
    let mut chain = [0u8; 32];
    new_root.copy_from_slice(&out[..32]);
    chain.copy_from_slice(&out[32..]);
    (new_root, chain)
}

/// KDF_CK: mk = HMAC(CK, 0x01), CK' = HMAC(CK, 0x02).
fn kdf_ck(chain_key: &[u8; 32]) -> ([u8; 32], [u8; 32]) {
    let message_key = hmac_sha256(chain_key, &[0x01]);
    let next_chain = hmac_sha256(chain_key, &[0x02]);
    (message_key, next_chain)
}

/// Expand a message key to ChaCha20-Poly1305 (key, nonce).
fn message_keys(message_key: &[u8; 32]) -> ([u8; 32], [u8; 12]) {
    let prk = hkdf_extract(&[], message_key);
    let mut out = [0u8; 44];
    hkdf_expand(&prk, MSG_INFO, &mut out);
    let mut key = [0u8; 32];
    let mut nonce = [0u8; 12];
    key.copy_from_slice(&out[..32]);
    nonce.copy_from_slice(&out[32..]);
    (key, nonce)
}

fn encode_header(dh_public: &[u8; 32], prev_n: u32, n: u32) -> [u8; HEADER_LEN] {
    let mut header = [0u8; HEADER_LEN];
    header[..32].copy_from_slice(dh_public);
    header[32..36].copy_from_slice(&prev_n.to_le_bytes());
    header[36..40].copy_from_slice(&n.to_le_bytes());
    header
}

fn decode_header(header: &[u8; HEADER_LEN]) -> ([u8; 32], u32, u32) {
    let mut dh_public = [0u8; 32];
    dh_public.copy_from_slice(&header[..32]);
    let prev_n = u32::from_le_bytes(header[32..36].try_into().unwrap());
    let n = u32::from_le_bytes(header[36..40].try_into().unwrap());
    (dh_public, prev_n, n)
}

/// One party's Double Ratchet state.
pub struct DoubleRatchet {
    root_key: [u8; 32],
    dh_self: SecretKey,
    dh_self_public: [u8; 32],
    dh_remote: Option<[u8; 32]>,
    chain_send: Option<[u8; 32]>,
    chain_recv: Option<[u8; 32]>,
    n_send: u32,
    n_recv: u32,
    prev_n: u32,
    skipped: HashMap<([u8; 32], u32), [u8; 32]>,
}

impl DoubleRatchet {
    /// Initiator initialization: `sk` from PQXDH, `remote_signed_prekey` is
    /// the responder's signed prekey public (its initial ratchet key).
    pub fn init_initiator(sk: [u8; 32], remote_signed_prekey: [u8; 32]) -> Self {
        let mut bytes = [0u8; 32];
        fill_random(&mut bytes);
        let dh_self = SecretKey::from_bytes(bytes);
        let dh_self_public = dh_self.public_key();
        let (root_key, chain_send) = kdf_rk(&sk, &dh_self.diffie_hellman(&remote_signed_prekey));
        DoubleRatchet {
            root_key,
            dh_self,
            dh_self_public,
            dh_remote: Some(remote_signed_prekey),
            chain_send: Some(chain_send),
            chain_recv: None,
            n_send: 0,
            n_recv: 0,
            prev_n: 0,
            skipped: HashMap::new(),
        }
    }

    /// Responder initialization: `sk` from PQXDH and the responder's signed
    /// prekey key (which becomes its initial ratchet key). It cannot send
    /// until it has received the initiator's first message.
    pub fn init_responder(sk: [u8; 32], signed_prekey: SecretKey) -> Self {
        let dh_self_public = signed_prekey.public_key();
        DoubleRatchet {
            root_key: sk,
            dh_self: signed_prekey,
            dh_self_public,
            dh_remote: None,
            chain_send: None,
            chain_recv: None,
            n_send: 0,
            n_recv: 0,
            prev_n: 0,
            skipped: HashMap::new(),
        }
    }

    /// Encrypt `plaintext`, binding `associated_data` (which the peer must
    /// supply identically to decrypt) alongside the header.
    pub fn encrypt(
        &mut self,
        plaintext: &[u8],
        associated_data: &[u8],
    ) -> Result<Message, RatchetError> {
        let chain = self
            .chain_send
            .ok_or(RatchetError::NotInitializedForSending)?;
        let (message_key, next_chain) = kdf_ck(&chain);
        self.chain_send = Some(next_chain);
        let header = encode_header(&self.dh_self_public, self.prev_n, self.n_send);
        self.n_send += 1;

        let (key, nonce) = message_keys(&message_key);
        let aad = concat_aad(&header, associated_data);
        let ciphertext = aead::seal(&key, &nonce, plaintext, &aad);
        Ok(Message { header, ciphertext })
    }

    /// Decrypt a [`Message`], advancing (or stepping) the ratchet as needed.
    /// Out-of-order and dropped messages are handled via stored skipped keys.
    pub fn decrypt(
        &mut self,
        message: &Message,
        associated_data: &[u8],
    ) -> Result<Vec<u8>, RatchetError> {
        let (remote_dh, prev_n, n) = decode_header(&message.header);

        // A key we already skipped past (out-of-order delivery).
        if let Some(message_key) = self.skipped.remove(&(remote_dh, n)) {
            return open(&message_key, message, associated_data);
        }

        let is_new_ratchet = match self.dh_remote {
            Some(current) => current != remote_dh,
            None => true,
        };
        if is_new_ratchet {
            self.skip_message_keys(prev_n)?;
            self.dh_ratchet(remote_dh);
        }
        self.skip_message_keys(n)?;

        let chain = self.chain_recv.ok_or(RatchetError::DecryptFailed)?;
        let (message_key, next_chain) = kdf_ck(&chain);
        self.chain_recv = Some(next_chain);
        self.n_recv += 1;
        open(&message_key, message, associated_data)
    }

    /// The current ratchet public key (exposed for tests/introspection).
    pub fn ratchet_public(&self) -> [u8; 32] {
        self.dh_self_public
    }

    /// Store the message keys of the current receiving chain up to `until`, so
    /// later-arriving earlier messages can still be decrypted.
    fn skip_message_keys(&mut self, until: u32) -> Result<(), RatchetError> {
        if until > self.n_recv.saturating_add(MAX_SKIP) {
            return Err(RatchetError::TooManySkipped);
        }
        let Some(mut chain) = self.chain_recv else {
            return Ok(());
        };
        let remote = self
            .dh_remote
            .expect("receiving chain implies a known remote ratchet key");
        while self.n_recv < until {
            let (message_key, next_chain) = kdf_ck(&chain);
            self.skipped.insert((remote, self.n_recv), message_key);
            chain = next_chain;
            self.n_recv += 1;
        }
        self.chain_recv = Some(chain);
        Ok(())
    }

    /// Perform a DH ratchet step on receiving a new remote ratchet key (§3.2).
    fn dh_ratchet(&mut self, remote_dh: [u8; 32]) {
        self.prev_n = self.n_send;
        self.n_send = 0;
        self.n_recv = 0;
        self.dh_remote = Some(remote_dh);

        let (root_key, chain_recv) =
            kdf_rk(&self.root_key, &self.dh_self.diffie_hellman(&remote_dh));
        self.root_key = root_key;
        self.chain_recv = Some(chain_recv);

        let mut bytes = [0u8; 32];
        fill_random(&mut bytes);
        let new_self = SecretKey::from_bytes(bytes);
        let new_public = new_self.public_key();
        let (root_key, chain_send) = kdf_rk(&self.root_key, &new_self.diffie_hellman(&remote_dh));
        self.root_key = root_key;
        self.chain_send = Some(chain_send);
        self.dh_self = new_self;
        self.dh_self_public = new_public;
    }
}

fn concat_aad(header: &[u8; HEADER_LEN], associated_data: &[u8]) -> Vec<u8> {
    let mut aad = Vec::with_capacity(HEADER_LEN + associated_data.len());
    aad.extend_from_slice(header);
    aad.extend_from_slice(associated_data);
    aad
}

fn open(
    message_key: &[u8; 32],
    message: &Message,
    associated_data: &[u8],
) -> Result<Vec<u8>, RatchetError> {
    let (key, nonce) = message_keys(message_key);
    let aad = concat_aad(&message.header, associated_data);
    aead::open(&key, &nonce, &message.ciphertext, &aad).ok_or(RatchetError::DecryptFailed)
}
