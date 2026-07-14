//! PQXDH — post-quantum extended triple Diffie-Hellman (see
//! `docs/CRYPTO_MATH.md` §2). The initiator combines four X25519 DHs with an
//! ML-KEM-768 encapsulation into a single root secret `SK`, so the session
//! holds if *either* elliptic DH or Module-LWE survives.

use aegis_crypto::x25519::SecretKey;
use aegis_crypto::{fill_random, hkdf_expand, hkdf_extract, ml_kem};

use crate::bundle::{PrekeyBundle, PrekeySecrets};
use crate::SessionError;

/// X3DH domain-separation prefix (32 × 0xFF), prepended to the HKDF input.
const F_PREFIX: [u8; 32] = [0xff; 32];
const PQXDH_INFO: &[u8] = b"aegis/pqxdh/v1";
const PQXDH_INFO_NO_OPK: &[u8] = b"aegis/pqxdh/v1-noopk";

/// The initial handshake message the initiator sends to the responder.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct InitialMessage {
    /// Initiator identity DH public key `IK_A`.
    pub identity_dh: [u8; 32],
    /// Initiator ephemeral public key `EK_A`.
    pub ephemeral: [u8; 32],
    /// ML-KEM-768 ciphertext `CT` encapsulated to the responder's PQ prekey.
    pub kem_ciphertext: Vec<u8>,
    /// Whether the responder's one-time prekey was consumed (selects the
    /// KDF domain string and tells the responder to mix `DH4`).
    pub used_one_time: bool,
}

/// SK = HKDF(salt=0^32, F ‖ DH1 ‖ DH2 ‖ DH3 [‖ DH4] ‖ SS, info, 32).
fn derive_sk(ikm: &[u8], used_one_time: bool) -> [u8; 32] {
    let prk = hkdf_extract(&[0u8; 32], ikm);
    let info = if used_one_time {
        PQXDH_INFO
    } else {
        PQXDH_INFO_NO_OPK
    };
    let mut sk = [0u8; 32];
    hkdf_expand(&prk, info, &mut sk);
    sk
}

/// Initiator side: derive the root secret `SK` and the [`InitialMessage`] to
/// send. `initiator_identity_dh` is the initiator's long-term identity DH key.
pub fn initiate(
    initiator_identity_dh: &SecretKey,
    bundle: &PrekeyBundle,
) -> ([u8; 32], InitialMessage) {
    let mut ek_bytes = [0u8; 32];
    fill_random(&mut ek_bytes);
    let ephemeral = SecretKey::from_bytes(ek_bytes);

    let dh1 = initiator_identity_dh.diffie_hellman(&bundle.signed_prekey);
    let dh2 = ephemeral.diffie_hellman(&bundle.identity_dh);
    let dh3 = ephemeral.diffie_hellman(&bundle.signed_prekey);
    let (kem_ciphertext, ss) = ml_kem::encapsulate(&bundle.pq_prekey);

    let mut ikm = Vec::with_capacity(32 * 6);
    ikm.extend_from_slice(&F_PREFIX);
    ikm.extend_from_slice(&dh1);
    ikm.extend_from_slice(&dh2);
    ikm.extend_from_slice(&dh3);
    let used_one_time = if let Some(opk) = bundle.one_time_prekey {
        ikm.extend_from_slice(&ephemeral.diffie_hellman(&opk));
        true
    } else {
        false
    };
    ikm.extend_from_slice(&ss);

    let sk = derive_sk(&ikm, used_one_time);
    let message = InitialMessage {
        identity_dh: initiator_identity_dh.public_key(),
        ephemeral: ephemeral.public_key(),
        kem_ciphertext,
        used_one_time,
    };
    (sk, message)
}

/// Responder side: recover the root secret `SK` from the initial message and
/// the responder's own prekey secrets.
pub fn respond(
    secrets: &PrekeySecrets,
    message: &InitialMessage,
) -> Result<[u8; 32], SessionError> {
    let dh1 = secrets.signed_prekey.diffie_hellman(&message.identity_dh);
    let dh2 = secrets.identity_dh.diffie_hellman(&message.ephemeral);
    let dh3 = secrets.signed_prekey.diffie_hellman(&message.ephemeral);
    let ss = ml_kem::decapsulate(&secrets.pq_prekey.dk, &message.kem_ciphertext);

    let mut ikm = Vec::with_capacity(32 * 6);
    ikm.extend_from_slice(&F_PREFIX);
    ikm.extend_from_slice(&dh1);
    ikm.extend_from_slice(&dh2);
    ikm.extend_from_slice(&dh3);
    if message.used_one_time {
        let opk = secrets
            .one_time_prekey
            .as_ref()
            .ok_or(SessionError::MissingOneTimePrekey)?;
        ikm.extend_from_slice(&opk.diffie_hellman(&message.ephemeral));
    }
    ikm.extend_from_slice(&ss);

    Ok(derive_sk(&ikm, message.used_one_time))
}
