//! Aegis identities, view keys, and the human-facing Aegis ID.
//!
//! An identity holds three keypairs:
//!
//! - the **view keypair** `(v, V)` — used to *detect* incoming messages via
//!   stealth addressing (`stealth` module);
//! - the **identity DH keypair** `(ik, IK)` — the long-term Diffie-Hellman
//!   key the PQXDH handshake binds to;
//! - the **identity signing key** `IK^sig` — an ML-DSA-65 (FIPS 204) keypair
//!   that authenticates prekey bundles at session setup (G8), per
//!   `docs/CRYPTO_MATH.md` §2.1.
//!
//! Because an ML-DSA public key is ~1.9 KB — far too large to paste around —
//! the shareable [`AegisId`] commits to `SHA-256(IK^sig)` (32 bytes) rather
//! than the key itself. The full signing key travels in the prekey bundle and
//! is checked against that hash before its signature is trusted.

use crate::stealth::{self, EphemeralPublic, StealthAddress, ViewPublicKey};
use aegis_crypto::ml_dsa;
use aegis_crypto::{fill_random, sha256, x25519::SecretKey};

/// A view keypair: the secret `v` and the published point `V = v·G`.
pub struct ViewKeypair {
    secret: SecretKey,
    public: ViewPublicKey,
}

impl ViewKeypair {
    /// Generate a fresh view keypair from OS randomness.
    pub fn generate() -> Self {
        let mut bytes = [0u8; 32];
        fill_random(&mut bytes);
        Self::from_secret_bytes(bytes)
    }

    /// Build a view keypair from a 32-byte secret scalar (clamped internally).
    pub fn from_secret_bytes(secret: [u8; 32]) -> Self {
        let secret = SecretKey::from_bytes(secret);
        let public = ViewPublicKey(secret.public_key());
        ViewKeypair { secret, public }
    }

    /// The published view public key `V`.
    pub fn public(&self) -> ViewPublicKey {
        self.public
    }

    /// Test whether a stored envelope `(ephemeral R, address)` is addressed to
    /// this identity. Recomputes `S' = v·R`, derives the tags, and checks the
    /// 1-byte view tag first (rejecting ~255/256 of foreign envelopes) before
    /// the full 16-byte address-tag compare.
    ///
    /// A degenerate (all-zero) shared secret is treated as a non-match rather
    /// than an error: it can only come from a malformed envelope, and scanning
    /// should simply skip it.
    pub fn matches(&self, ephemeral: &EphemeralPublic, address: &StealthAddress) -> bool {
        let shared = match stealth::checked_shared(self.secret.diffie_hellman(&ephemeral.0)) {
            Ok(s) => s,
            Err(_) => return false,
        };
        let recomputed = stealth::tags_from_shared(&shared, &ephemeral.0, &self.public.0);
        // view_tag is a deliberately coarse 1-byte fast-reject; the full 16-byte
        // addr_tag confirm is constant-time so scan timing can't leak a partial
        // tag match.
        recomputed.view_tag == address.view_tag
            && aegis_crypto::ct_eq(&recomputed.addr_tag, &address.addr_tag)
    }

    /// Like [`matches`](Self::matches), but on a match also returns the
    /// per-message **envelope key** so the caller can decrypt a sealed
    /// envelope addressed to this identity. Returns `None` if the envelope is
    /// not ours (or is degenerate). One DH, one derivation — no double work.
    pub fn open(&self, ephemeral: &EphemeralPublic, address: &StealthAddress) -> Option<[u8; 32]> {
        let shared = stealth::checked_shared(self.secret.diffie_hellman(&ephemeral.0)).ok()?;
        let recomputed = stealth::tags_from_shared(&shared, &ephemeral.0, &self.public.0);
        if recomputed.view_tag == address.view_tag
            && aegis_crypto::ct_eq(&recomputed.addr_tag, &address.addr_tag)
        {
            Some(stealth::envelope_key_from_shared(
                &shared,
                &ephemeral.0,
                &self.public.0,
            ))
        } else {
            None
        }
    }
}

/// A full Aegis identity: view keypair, identity DH keypair, and ML-DSA
/// signing keypair.
pub struct Identity {
    identity_dh: SecretKey,
    identity_dh_public: [u8; 32],
    view: ViewKeypair,
    signing_public: Vec<u8>,
    signing_secret: Vec<u8>,
}

impl Identity {
    /// Generate a fresh identity from OS randomness.
    pub fn generate() -> Self {
        let mut ik = [0u8; 32];
        let mut v = [0u8; 32];
        let mut sig = [0u8; 32];
        fill_random(&mut ik);
        fill_random(&mut v);
        fill_random(&mut sig);
        Self::from_secret_bytes(ik, v, sig)
    }

    /// Build an identity from its secret seeds (X25519 scalars are clamped
    /// internally; `signing_seed` is the ML-DSA-65 KeyGen seed). Deterministic
    /// — used for reproducible tests and for restoring an identity from seeds.
    pub fn from_secret_bytes(
        identity_dh: [u8; 32],
        view: [u8; 32],
        signing_seed: [u8; 32],
    ) -> Self {
        let identity_dh = SecretKey::from_bytes(identity_dh);
        let identity_dh_public = identity_dh.public_key();
        let (signing_public, signing_secret) = ml_dsa::keypair_from_seed(&signing_seed);
        Identity {
            identity_dh,
            identity_dh_public,
            view: ViewKeypair::from_secret_bytes(view),
            signing_public,
            signing_secret,
        }
    }

    /// The view keypair (for scanning incoming messages).
    pub fn view(&self) -> &ViewKeypair {
        &self.view
    }

    /// The published view public key `V`.
    pub fn view_public(&self) -> ViewPublicKey {
        self.view.public()
    }

    /// The long-term identity DH public key `IK` (used by PQXDH).
    pub fn identity_dh_public(&self) -> [u8; 32] {
        self.identity_dh_public
    }

    /// Perform a raw X25519 DH with the identity key. The PQXDH handshake is
    /// the intended consumer.
    pub fn identity_dh(&self, their_public: &[u8; 32]) -> [u8; 32] {
        self.identity_dh.diffie_hellman(their_public)
    }

    /// The ML-DSA-65 identity signing public key `IK^sig`.
    pub fn signing_public(&self) -> &[u8] {
        &self.signing_public
    }

    /// Sign `message` with the identity signing key (ML-DSA-65).
    pub fn sign(&self, message: &[u8]) -> Vec<u8> {
        ml_dsa::sign(&self.signing_secret, message)
    }

    /// The shareable Aegis ID committing to `(IK, V, SHA-256(IK^sig))`.
    pub fn aegis_id(&self) -> AegisId {
        AegisId::from_keys(
            &self.identity_dh_public,
            &self.view.public().0,
            &sha256(&self.signing_public),
        )
    }
}

/// Errors decoding an [`AegisId`].
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AegisIdError {
    /// Missing/incorrect `aegis:` prefix.
    BadPrefix,
    /// A character outside the base32 alphabet.
    BadCharacter,
    /// Decoded payload has the wrong length.
    BadLength,
    /// Unknown version byte.
    BadVersion,
    /// Checksum did not match — the ID was mistyped or corrupted.
    BadChecksum,
}

impl core::fmt::Display for AegisIdError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        let s = match self {
            AegisIdError::BadPrefix => "missing 'aegis:' prefix",
            AegisIdError::BadCharacter => "invalid base32 character",
            AegisIdError::BadLength => "wrong decoded length",
            AegisIdError::BadVersion => "unknown Aegis ID version",
            AegisIdError::BadChecksum => "checksum mismatch (mistyped ID?)",
        };
        f.write_str(s)
    }
}

impl std::error::Error for AegisIdError {}

const AEGIS_ID_PREFIX: &str = "aegis:";
const AEGIS_ID_VERSION: u8 = 1;
const CHECKSUM_LEN: usize = 4;
// version(1) + identity_dh(32) + view(32) + signing-key hash(32)
const PAYLOAD_LEN: usize = 1 + 32 + 32 + 32;

/// A shareable Aegis identity string: `aegis:` + base32(version ‖ IK ‖ V ‖
/// H(IK^sig) ‖ checksum). The checksum is the first 4 bytes of
/// `SHA-256(version ‖ IK ‖ V ‖ H(IK^sig))`, so a mistyped ID is rejected
/// rather than silently pointing at a wrong key. The signing-key hash lets a
/// recipient bind a prekey bundle's signing key to this identity (§2.1).
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct AegisId {
    identity_dh_public: [u8; 32],
    view_public: [u8; 32],
    signing_key_hash: [u8; 32],
}

impl AegisId {
    fn from_keys(
        identity_dh_public: &[u8; 32],
        view_public: &[u8; 32],
        signing_key_hash: &[u8; 32],
    ) -> Self {
        AegisId {
            identity_dh_public: *identity_dh_public,
            view_public: *view_public,
            signing_key_hash: *signing_key_hash,
        }
    }

    /// The committed identity DH public key `IK`.
    pub fn identity_dh_public(&self) -> [u8; 32] {
        self.identity_dh_public
    }

    /// The committed view public key `V`.
    pub fn view_public(&self) -> ViewPublicKey {
        ViewPublicKey(self.view_public)
    }

    /// The committed `SHA-256(IK^sig)` of the identity signing key.
    pub fn signing_key_hash(&self) -> [u8; 32] {
        self.signing_key_hash
    }

    /// Check that `signing_public` is the identity signing key this ID commits
    /// to — the binding that upgrades a self-consistent bundle signature into
    /// authentication of *this* identity (defeats bundle substitution / MITM).
    pub fn verify_signing_key(&self, signing_public: &[u8]) -> bool {
        sha256(signing_public) == self.signing_key_hash
    }

    fn payload(&self) -> [u8; PAYLOAD_LEN] {
        let mut p = [0u8; PAYLOAD_LEN];
        p[0] = AEGIS_ID_VERSION;
        p[1..33].copy_from_slice(&self.identity_dh_public);
        p[33..65].copy_from_slice(&self.view_public);
        p[65..97].copy_from_slice(&self.signing_key_hash);
        p
    }

    /// Encode to the shareable `aegis:...` string.
    pub fn encode(&self) -> String {
        let payload = self.payload();
        let checksum = sha256(&payload);
        let mut framed = Vec::with_capacity(PAYLOAD_LEN + CHECKSUM_LEN);
        framed.extend_from_slice(&payload);
        framed.extend_from_slice(&checksum[..CHECKSUM_LEN]);
        format!("{AEGIS_ID_PREFIX}{}", base32_encode(&framed))
    }

    /// Decode from a shareable `aegis:...` string, verifying the checksum.
    pub fn decode(s: &str) -> Result<AegisId, AegisIdError> {
        let body = s
            .strip_prefix(AEGIS_ID_PREFIX)
            .ok_or(AegisIdError::BadPrefix)?;
        let framed = base32_decode(body)?;
        if framed.len() != PAYLOAD_LEN + CHECKSUM_LEN {
            return Err(AegisIdError::BadLength);
        }
        let (payload, checksum) = framed.split_at(PAYLOAD_LEN);
        if payload[0] != AEGIS_ID_VERSION {
            return Err(AegisIdError::BadVersion);
        }
        let expected = sha256(payload);
        if checksum != &expected[..CHECKSUM_LEN] {
            return Err(AegisIdError::BadChecksum);
        }
        let mut identity_dh_public = [0u8; 32];
        identity_dh_public.copy_from_slice(&payload[1..33]);
        let mut view_public = [0u8; 32];
        view_public.copy_from_slice(&payload[33..65]);
        let mut signing_key_hash = [0u8; 32];
        signing_key_hash.copy_from_slice(&payload[65..97]);
        Ok(AegisId {
            identity_dh_public,
            view_public,
            signing_key_hash,
        })
    }

    /// A stable 32-byte fingerprint of everything this identity commits to.
    pub fn fingerprint(&self) -> [u8; 32] {
        let mut input = Vec::with_capacity(96);
        input.extend_from_slice(&self.identity_dh_public);
        input.extend_from_slice(&self.view_public);
        input.extend_from_slice(&self.signing_key_hash);
        sha256(&input)
    }
}

const SAFETY_DOMAIN: &[u8] = b"aegis/safety-number/v1";

/// A **safety number** (SAS): a short, order-independent decimal fingerprint of
/// two identities that both parties compute identically and compare out of band
/// (read it aloud, scan a QR). If the numbers match, no one substituted a key in
/// the middle — it turns a self-consistent handshake into human-verified
/// authentication of *these two* identities.
pub fn safety_number(a: &AegisId, b: &AegisId) -> String {
    let (fa, fb) = (a.fingerprint(), b.fingerprint());
    let (x, y) = if fa <= fb { (fa, fb) } else { (fb, fa) };
    let mut input = Vec::with_capacity(SAFETY_DOMAIN.len() + 64);
    input.extend_from_slice(SAFETY_DOMAIN);
    input.extend_from_slice(&x);
    input.extend_from_slice(&y);
    let h = sha256(&input);
    // 8 groups of 5 digits (each 4 hash bytes → u32 mod 100000).
    let mut groups = Vec::with_capacity(8);
    for chunk in h.chunks_exact(4).take(8) {
        let n = u32::from_be_bytes(chunk.try_into().unwrap()) % 100_000;
        groups.push(format!("{n:05}"));
    }
    groups.join(" ")
}

impl core::fmt::Display for AegisId {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(&self.encode())
    }
}

// --- RFC 4648 base32 (no padding), lowercase, self-contained -------------

const B32_ALPHABET: &[u8; 32] = b"abcdefghijklmnopqrstuvwxyz234567";

fn base32_encode(data: &[u8]) -> String {
    let mut out = String::with_capacity(data.len().div_ceil(5) * 8);
    let mut buffer: u32 = 0;
    let mut bits: u32 = 0;
    for &byte in data {
        buffer = (buffer << 8) | byte as u32;
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            let idx = ((buffer >> bits) & 0x1f) as usize;
            out.push(B32_ALPHABET[idx] as char);
        }
    }
    if bits > 0 {
        let idx = ((buffer << (5 - bits)) & 0x1f) as usize;
        out.push(B32_ALPHABET[idx] as char);
    }
    out
}

fn base32_decode(s: &str) -> Result<Vec<u8>, AegisIdError> {
    let mut out = Vec::with_capacity(s.len() * 5 / 8);
    let mut buffer: u32 = 0;
    let mut bits: u32 = 0;
    for ch in s.bytes() {
        let val = match ch {
            b'a'..=b'z' => ch - b'a',
            b'2'..=b'7' => ch - b'2' + 26,
            _ => return Err(AegisIdError::BadCharacter),
        } as u32;
        buffer = (buffer << 5) | val;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
        }
    }
    Ok(out)
}
