//! The Double Ratchet with an **ongoing post-quantum ratchet** (see
//! `docs/CRYPTO_MATH.md` §3–§4).
//!
//! On top of the classical construction — a symmetric-key ratchet for a fresh
//! key per message (forward secrecy, G2) and an X25519 DH ratchet that
//! self-heals after compromise (G3) — every DH ratchet step also mixes an
//! **ML-KEM-768 re-encapsulation** into the root KDF. So the *whole*
//! conversation stays post-quantum confidential (G4), not just its first
//! message: an adversary who breaks the elliptic half of every step still
//! faces Module-LWE on the other half.
//!
//! Each ratchet advertisement carries the sender's X25519 ratchet key **and**
//! an ML-KEM encapsulation key; each ratchet header also carries the KEM
//! ciphertext encapsulated to the peer's last-advertised key. Both sides mix
//! `DH ‖ SS_kem` into the root at the step, deriving matching chains.
//!
//! Size note: the KEM key + ciphertext ride in every header (~2.3 KB), which
//! keeps the ratchet robust to dropped messages. Signal's SPQR chunks the
//! ciphertext across messages and runs the KEM at a slower cadence to shrink
//! this — the planned optimization; the mixing math is unchanged.

use std::collections::HashMap;

use aegis_crypto::ml_kem::{self, CT_LEN, EK_LEN};
use aegis_crypto::x25519::SecretKey;
use aegis_crypto::{aead, fill_random, hkdf_expand, hkdf_extract, hmac_sha256};

const MAX_SKIP: u32 = 1000;
/// Header layout: X25519 ratchet key (32) ‖ ML-KEM ek (1184) ‖ ML-KEM ct
/// (1088) ‖ prev-chain length (4 LE) ‖ N (4 LE).
const HEADER_LEN: usize = 32 + EK_LEN + CT_LEN + 4 + 4;
const ROOT_INFO: &[u8] = b"aegis/ratchet/root/pq/v1";
const MSG_INFO: &[u8] = b"aegis/ratchet/msg";
/// Version tag on serialized ratchet state; bump on a format change.
const STATE_VERSION: u8 = 1;

/// An encrypted Double Ratchet message: cleartext header + AEAD ciphertext.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Message {
    /// `x_pub ‖ kem_ek ‖ kem_ct ‖ prev_n ‖ n` — authenticated (AAD), not
    /// encrypted. `HEADER_LEN` bytes.
    pub header: Vec<u8>,
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
    /// The header was malformed (wrong length).
    BadHeader,
    /// This ratchet has not yet received a message, so it cannot send (the
    /// responder must receive the initiator's first message first).
    NotInitializedForSending,
}

// --- key-derivation functions (§3.1, §4) ---------------------------------

/// KDF_RK with a post-quantum mix: HKDF(salt=RK, ikm=dh_out ‖ kem_ss, info, 64)
/// → (RK', CK).
fn kdf_rk_pq(root_key: &[u8; 32], dh_out: &[u8; 32], kem_ss: &[u8; 32]) -> ([u8; 32], [u8; 32]) {
    let mut ikm = [0u8; 64];
    ikm[..32].copy_from_slice(dh_out);
    ikm[32..].copy_from_slice(kem_ss);
    let prk = hkdf_extract(root_key, &ikm);
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

/// A parsed ratchet header.
struct Header {
    dh_public: [u8; 32],
    kem_ek: Vec<u8>,
    kem_ct: Vec<u8>,
    prev_n: u32,
    n: u32,
}

fn encode_header(
    dh_public: &[u8; 32],
    kem_ek: &[u8],
    kem_ct: &[u8],
    prev_n: u32,
    n: u32,
) -> Vec<u8> {
    debug_assert_eq!(kem_ek.len(), EK_LEN);
    debug_assert_eq!(kem_ct.len(), CT_LEN);
    let mut header = Vec::with_capacity(HEADER_LEN);
    header.extend_from_slice(dh_public);
    header.extend_from_slice(kem_ek);
    header.extend_from_slice(kem_ct);
    header.extend_from_slice(&prev_n.to_le_bytes());
    header.extend_from_slice(&n.to_le_bytes());
    header
}

fn decode_header(header: &[u8]) -> Result<Header, RatchetError> {
    if header.len() != HEADER_LEN {
        return Err(RatchetError::BadHeader);
    }
    let mut dh_public = [0u8; 32];
    dh_public.copy_from_slice(&header[..32]);
    let kem_ek = header[32..32 + EK_LEN].to_vec();
    let kem_ct = header[32 + EK_LEN..32 + EK_LEN + CT_LEN].to_vec();
    let rest = &header[32 + EK_LEN + CT_LEN..];
    let prev_n = u32::from_le_bytes(rest[..4].try_into().unwrap());
    let n = u32::from_le_bytes(rest[4..8].try_into().unwrap());
    Ok(Header {
        dh_public,
        kem_ek,
        kem_ct,
        prev_n,
        n,
    })
}

/// One party's Double Ratchet state.
pub struct DoubleRatchet {
    root_key: [u8; 32],
    dh_self: SecretKey,
    dh_self_public: [u8; 32],
    kem_self: ml_kem::KeyPair,
    dh_remote: Option<[u8; 32]>,
    /// The KEM ciphertext to advertise in headers of the current sending chain
    /// (encapsulated to the peer's ratchet KEM key). `Some` iff we can send.
    pending_kem_ct: Option<Vec<u8>>,
    chain_send: Option<[u8; 32]>,
    chain_recv: Option<[u8; 32]>,
    n_send: u32,
    n_recv: u32,
    prev_n: u32,
    skipped: HashMap<([u8; 32], u32), [u8; 32]>,
}

impl DoubleRatchet {
    /// Initiator initialization: `sk` from PQXDH; `remote_signed_prekey` is the
    /// responder's signed prekey public (its initial X25519 ratchet key), and
    /// `remote_ratchet_kem` is the responder's initial ratchet ML-KEM key, so
    /// even the first message is post-quantum ratcheted.
    pub fn init_initiator(
        sk: [u8; 32],
        remote_signed_prekey: [u8; 32],
        remote_ratchet_kem: &[u8],
    ) -> Self {
        let mut bytes = [0u8; 32];
        fill_random(&mut bytes);
        let dh_self = SecretKey::from_bytes(bytes);
        let dh_self_public = dh_self.public_key();
        let kem_self = ml_kem::KeyPair::generate();

        let (kem_ct, kem_ss) = ml_kem::encapsulate(remote_ratchet_kem);
        let (root_key, chain_send) =
            kdf_rk_pq(&sk, &dh_self.diffie_hellman(&remote_signed_prekey), &kem_ss);
        DoubleRatchet {
            root_key,
            dh_self,
            dh_self_public,
            kem_self,
            dh_remote: Some(remote_signed_prekey),
            pending_kem_ct: Some(kem_ct),
            chain_send: Some(chain_send),
            chain_recv: None,
            n_send: 0,
            n_recv: 0,
            prev_n: 0,
            skipped: HashMap::new(),
        }
    }

    /// Responder initialization: `sk` from PQXDH, the responder's signed prekey
    /// key (its initial X25519 ratchet key) and ratchet ML-KEM keypair. It
    /// cannot send until it has received the initiator's first message.
    pub fn init_responder(
        sk: [u8; 32],
        signed_prekey: SecretKey,
        ratchet_kem: ml_kem::KeyPair,
    ) -> Self {
        let dh_self_public = signed_prekey.public_key();
        DoubleRatchet {
            root_key: sk,
            dh_self: signed_prekey,
            dh_self_public,
            kem_self: ratchet_kem,
            dh_remote: None,
            pending_kem_ct: None,
            chain_send: None,
            chain_recv: None,
            n_send: 0,
            n_recv: 0,
            prev_n: 0,
            skipped: HashMap::new(),
        }
    }

    /// Serialize the full ratchet state to bytes so a conversation survives a
    /// restart. The output contains long-term secrets (the X25519 ratchet key,
    /// the ML-KEM secret key, chain and root keys, skipped message keys) — store
    /// it only where the app's own data lives, never on the relay.
    pub fn serialize(&self) -> Vec<u8> {
        let mut w = Vec::new();
        w.push(STATE_VERSION);
        w.extend_from_slice(&self.root_key);
        w.extend_from_slice(&self.dh_self.to_bytes());
        w.extend_from_slice(&self.dh_self_public);
        put_bytes(&mut w, &self.kem_self.ek);
        put_bytes(&mut w, &self.kem_self.dk);
        put_opt32(&mut w, &self.dh_remote);
        put_opt_bytes(&mut w, self.pending_kem_ct.as_deref());
        put_opt32(&mut w, &self.chain_send);
        put_opt32(&mut w, &self.chain_recv);
        w.extend_from_slice(&self.n_send.to_le_bytes());
        w.extend_from_slice(&self.n_recv.to_le_bytes());
        w.extend_from_slice(&self.prev_n.to_le_bytes());
        w.extend_from_slice(&(self.skipped.len() as u32).to_le_bytes());
        for ((remote, n), mk) in &self.skipped {
            w.extend_from_slice(remote);
            w.extend_from_slice(&n.to_le_bytes());
            w.extend_from_slice(mk);
        }
        w
    }

    /// Reconstruct a ratchet from [`serialize`](Self::serialize). Returns `None`
    /// if the bytes are truncated or the version is unknown.
    pub fn deserialize(bytes: &[u8]) -> Option<Self> {
        let mut r = StateReader::new(bytes);
        if r.u8()? != STATE_VERSION {
            return None;
        }
        let root_key = r.array32()?;
        let dh_self = SecretKey::from_bytes(r.array32()?);
        let dh_self_public = r.array32()?;
        let ek = r.bytes()?.to_vec();
        let dk = r.bytes()?.to_vec();
        let dh_remote = r.opt32()?;
        let pending_kem_ct = r.opt_bytes()?;
        let chain_send = r.opt32()?;
        let chain_recv = r.opt32()?;
        let n_send = r.u32()?;
        let n_recv = r.u32()?;
        let prev_n = r.u32()?;
        let skip_count = r.u32()? as usize;
        let mut skipped = HashMap::with_capacity(skip_count);
        for _ in 0..skip_count {
            let remote = r.array32()?;
            let n = r.u32()?;
            let mk = r.array32()?;
            skipped.insert((remote, n), mk);
        }
        Some(DoubleRatchet {
            root_key,
            dh_self,
            dh_self_public,
            kem_self: ml_kem::KeyPair { ek, dk },
            dh_remote,
            pending_kem_ct,
            chain_send,
            chain_recv,
            n_send,
            n_recv,
            prev_n,
            skipped,
        })
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
        let kem_ct = self
            .pending_kem_ct
            .as_ref()
            .ok_or(RatchetError::NotInitializedForSending)?;
        let (message_key, next_chain) = kdf_ck(&chain);
        self.chain_send = Some(next_chain);
        let header = encode_header(
            &self.dh_self_public,
            &self.kem_self.ek,
            kem_ct,
            self.prev_n,
            self.n_send,
        );
        self.n_send += 1;

        let (key, nonce) = message_keys(&message_key);
        let aad = concat_aad(&header, associated_data);
        let ciphertext = aead::seal(&key, &nonce, plaintext, &aad);
        Ok(Message { header, ciphertext })
    }

    /// Decrypt a [`Message`], advancing (or stepping) the ratchet as needed.
    /// Out-of-order and dropped messages within a chain are handled via stored
    /// skipped keys.
    pub fn decrypt(
        &mut self,
        message: &Message,
        associated_data: &[u8],
    ) -> Result<Vec<u8>, RatchetError> {
        let header = decode_header(&message.header)?;

        // A key we already skipped past (out-of-order delivery).
        if let Some(message_key) = self.skipped.remove(&(header.dh_public, header.n)) {
            return open(&message_key, message, associated_data);
        }

        let is_new_ratchet = match self.dh_remote {
            Some(current) => current != header.dh_public,
            None => true,
        };
        if is_new_ratchet {
            self.skip_message_keys(header.prev_n)?;
            self.dh_ratchet(&header)?;
        }
        self.skip_message_keys(header.n)?;

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

    /// Store the message keys of the current receiving chain up to `until`.
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

    /// Perform a DH+KEM ratchet step on receiving a new remote ratchet key
    /// (§3.2, §4): mix `DH(self, remote) ‖ SS_kem` into the root for both the
    /// new receiving and the new sending chain.
    fn dh_ratchet(&mut self, header: &Header) -> Result<(), RatchetError> {
        self.prev_n = self.n_send;
        self.n_send = 0;
        self.n_recv = 0;

        // Receiving chain: decapsulate the ct the peer encapsulated to our
        // current ratchet KEM key, and mix it with the DH.
        let ss_recv = ml_kem::decapsulate(&self.kem_self.dk, &header.kem_ct);
        let (root_key, chain_recv) = kdf_rk_pq(
            &self.root_key,
            &self.dh_self.diffie_hellman(&header.dh_public),
            &ss_recv,
        );
        self.root_key = root_key;
        self.chain_recv = Some(chain_recv);
        self.dh_remote = Some(header.dh_public);

        // Sending chain: fresh X25519 + fresh ML-KEM keypair; encapsulate to the
        // peer's advertised ratchet KEM key and mix that in.
        let mut bytes = [0u8; 32];
        fill_random(&mut bytes);
        let new_self = SecretKey::from_bytes(bytes);
        let new_public = new_self.public_key();
        let new_kem = ml_kem::KeyPair::generate();
        let (kem_ct, ss_send) = ml_kem::encapsulate(&header.kem_ek);
        let (root_key, chain_send) = kdf_rk_pq(
            &self.root_key,
            &new_self.diffie_hellman(&header.dh_public),
            &ss_send,
        );
        self.root_key = root_key;
        self.chain_send = Some(chain_send);
        self.pending_kem_ct = Some(kem_ct);
        self.dh_self = new_self;
        self.dh_self_public = new_public;
        self.kem_self = new_kem;
        Ok(())
    }
}

// --- serialization helpers (see `DoubleRatchet::serialize`) --------------

fn put_bytes(w: &mut Vec<u8>, bytes: &[u8]) {
    w.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
    w.extend_from_slice(bytes);
}

fn put_opt32(w: &mut Vec<u8>, opt: &Option<[u8; 32]>) {
    match opt {
        Some(b) => {
            w.push(1);
            w.extend_from_slice(b);
        }
        None => w.push(0),
    }
}

fn put_opt_bytes(w: &mut Vec<u8>, opt: Option<&[u8]>) {
    match opt {
        Some(b) => {
            w.push(1);
            put_bytes(w, b);
        }
        None => w.push(0),
    }
}

struct StateReader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> StateReader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        StateReader { buf, pos: 0 }
    }
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let end = self.pos.checked_add(n)?;
        let s = self.buf.get(self.pos..end)?;
        self.pos = end;
        Some(s)
    }
    fn u8(&mut self) -> Option<u8> {
        Some(self.take(1)?[0])
    }
    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_le_bytes(self.take(4)?.try_into().ok()?))
    }
    fn array32(&mut self) -> Option<[u8; 32]> {
        self.take(32)?.try_into().ok()
    }
    fn bytes(&mut self) -> Option<&'a [u8]> {
        let n = self.u32()? as usize;
        self.take(n)
    }
    fn opt32(&mut self) -> Option<Option<[u8; 32]>> {
        match self.u8()? {
            0 => Some(None),
            1 => Some(Some(self.array32()?)),
            _ => None,
        }
    }
    fn opt_bytes(&mut self) -> Option<Option<Vec<u8>>> {
        match self.u8()? {
            0 => Some(None),
            1 => Some(Some(self.bytes()?.to_vec())),
            _ => None,
        }
    }
}

fn concat_aad(header: &[u8], associated_data: &[u8]) -> Vec<u8> {
    let mut aad = Vec::with_capacity(header.len() + associated_data.len());
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
