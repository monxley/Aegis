//! # aegis-mailbox — Phase 2
//!
//! Blind store-and-forward delivery for Aegis (Layer 4a of
//! [`AEGIS_PROTOCOL.md`](../../../AEGIS_PROTOCOL.md) §5). It ties the stealth
//! addressing of `aegis-identity` (recipient anonymity, G5) to a **sealed
//! sender** envelope (G6), so the relay that stores a message learns neither
//! who it is *for* nor who it is *from* — only a one-time address, an ephemeral
//! public key, and an opaque ciphertext.
//!
//! ```text
//! sender:  (address, R, K_env) = stealth::create_sealed(recipient_view)
//!          envelope = { address, R, AEAD_{K_env}(inner) }
//! relay:   stores envelope under `address` — sees nothing linkable
//! recipient: scans new envelopes with its view key; on a match, derives K_env
//!            and opens `inner`
//! ```
//!
//! The `inner` bytes are opaque to this layer — typically a session-layer
//! payload (a PQXDH initial message or a Double Ratchet message from
//! `aegis-session`). Wrapping them here hides even the ratchet header and the
//! sender's identity from the relay.
//!
//! The [`MailboxStore`] trait models the relay; [`InMemoryStore`] is a local
//! implementation. A real deployment points it at a Ciphra blind server (which
//! stores sealed bytes and holds no keys), but the envelope format and the
//! relay's blindness are the same either way.

use aegis_crypto::aead;
use aegis_identity::stealth;
use aegis_identity::{EphemeralPublic, StealthAddress, StealthError, ViewKeypair, ViewPublicKey};

/// The envelope AEAD binds the address and ephemeral so a relay cannot move a
/// ciphertext to a different address undetected.
const ENVELOPE_AAD_DOMAIN: &[u8] = b"aegis/mailbox/v1";

/// A fixed all-zero nonce is safe here: the envelope key is derived from a
/// fresh per-message ephemeral (see `aegis-identity`'s `envelope_key_*`), so a
/// given key seals exactly one envelope — the `(key, nonce)` pair never repeats.
const ENVELOPE_NONCE: [u8; 12] = [0u8; 12];

/// A sealed message as it sits on the relay. Everything here is either a
/// one-time value or opaque ciphertext.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Envelope {
    /// One-time stealth address (the relay's storage key).
    pub address: StealthAddress,
    /// Ephemeral public `R`, needed by the recipient to recompute the shared
    /// secret while scanning.
    pub ephemeral: EphemeralPublic,
    /// AEAD-sealed payload, openable only by the addressed recipient.
    pub ciphertext: Vec<u8>,
}

fn envelope_aad(address: &StealthAddress, ephemeral: &EphemeralPublic) -> Vec<u8> {
    let mut aad = Vec::with_capacity(ENVELOPE_AAD_DOMAIN.len() + 16 + 1 + 32);
    aad.extend_from_slice(ENVELOPE_AAD_DOMAIN);
    aad.extend_from_slice(&address.addr_tag);
    aad.push(address.view_tag);
    aad.extend_from_slice(&ephemeral.0);
    aad
}

/// Seal `inner` for `recipient` (their published view key), producing an
/// [`Envelope`] to hand to the relay. A fresh stealth address is drawn, so
/// repeated sends to the same recipient are unlinkable.
pub fn seal(recipient: &ViewPublicKey, inner: &[u8]) -> Result<Envelope, StealthError> {
    let sealed = stealth::create_sealed(recipient)?;
    let aad = envelope_aad(&sealed.address, &sealed.ephemeral);
    let ciphertext = aead::seal(&sealed.envelope_key, &ENVELOPE_NONCE, inner, &aad);
    Ok(Envelope {
        address: sealed.address,
        ephemeral: sealed.ephemeral,
        ciphertext,
    })
}

/// Try to open `envelope` with `view` (a recipient's view keypair). Returns the
/// `inner` payload if the envelope is addressed to this recipient and intact,
/// or `None` otherwise (not ours, or tampered). Cheap to call on every stored
/// envelope: it does a single DH and short-circuits on the 1-byte view tag.
pub fn open(view: &ViewKeypair, envelope: &Envelope) -> Option<Vec<u8>> {
    let key = view.open(&envelope.ephemeral, &envelope.address)?;
    let aad = envelope_aad(&envelope.address, &envelope.ephemeral);
    aead::open(&key, &ENVELOPE_NONCE, &envelope.ciphertext, &aad)
}

/// A store-and-forward relay: an append-only log of sealed envelopes. Blind by
/// construction — it never sees a key.
pub trait MailboxStore {
    /// Store an envelope. Returns nothing; the relay cannot read it.
    fn put(&mut self, envelope: Envelope);

    /// Return every envelope with index `>= cursor`, and the new cursor. A
    /// recipient scans these with its view key.
    fn fetch_since(&self, cursor: usize) -> (usize, Vec<Envelope>);
}

/// A simple in-memory [`MailboxStore`] for local use and tests.
#[derive(Default)]
pub struct InMemoryStore {
    log: Vec<Envelope>,
}

impl InMemoryStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Total number of stored envelopes.
    pub fn len(&self) -> usize {
        self.log.len()
    }

    /// Whether the store is empty.
    pub fn is_empty(&self) -> bool {
        self.log.is_empty()
    }
}

impl MailboxStore for InMemoryStore {
    fn put(&mut self, envelope: Envelope) {
        self.log.push(envelope);
    }

    fn fetch_since(&self, cursor: usize) -> (usize, Vec<Envelope>) {
        let cursor = cursor.min(self.log.len());
        (self.log.len(), self.log[cursor..].to_vec())
    }
}

/// Seal `inner` for `recipient` and deposit it in `store`.
pub fn send(
    store: &mut impl MailboxStore,
    recipient: &ViewPublicKey,
    inner: &[u8],
) -> Result<(), StealthError> {
    store.put(seal(recipient, inner)?);
    Ok(())
}

/// Scan the store from `cursor` and return the new cursor plus the `inner`
/// payloads of every envelope addressed to `view`. Envelopes for other
/// recipients are silently skipped.
pub fn receive(
    store: &impl MailboxStore,
    view: &ViewKeypair,
    cursor: usize,
) -> (usize, Vec<Vec<u8>>) {
    let (next, envelopes) = store.fetch_since(cursor);
    let mine = envelopes.iter().filter_map(|e| open(view, e)).collect();
    (next, mine)
}

#[cfg(test)]
mod tests {
    use super::*;
    use aegis_identity::Identity;

    fn identity(a: u8, b: u8) -> Identity {
        Identity::from_secret_bytes([a; 32], [b; 32], [a ^ b ^ 0x5a; 32])
    }

    #[test]
    fn seal_open_round_trip() {
        let bob = identity(1, 2);
        let env = seal(&bob.view_public(), b"hello bob").unwrap();
        assert_eq!(open(bob.view(), &env).unwrap(), b"hello bob");
    }

    #[test]
    fn a_different_recipient_cannot_open() {
        let bob = identity(1, 2);
        let mallory = identity(3, 4);
        let env = seal(&bob.view_public(), b"for bob").unwrap();
        assert!(open(mallory.view(), &env).is_none());
    }

    #[test]
    fn tampered_ciphertext_is_rejected() {
        let bob = identity(1, 2);
        let mut env = seal(&bob.view_public(), b"secret").unwrap();
        env.ciphertext[0] ^= 1;
        assert!(open(bob.view(), &env).is_none());
    }

    #[test]
    fn moving_a_ciphertext_to_another_address_is_rejected() {
        // Relay tries to swap ciphertexts between two envelopes for Bob.
        let bob = identity(1, 2);
        let a = seal(&bob.view_public(), b"message a").unwrap();
        let b = seal(&bob.view_public(), b"message b").unwrap();
        let frankenstein = Envelope {
            address: a.address,
            ephemeral: a.ephemeral,
            ciphertext: b.ciphertext,
        };
        assert!(open(bob.view(), &frankenstein).is_none());
    }

    #[test]
    fn envelopes_to_one_recipient_are_unlinkable() {
        let bob = identity(5, 6);
        let mut tags = std::collections::HashSet::new();
        for _ in 0..64 {
            let env = seal(&bob.view_public(), b"x").unwrap();
            assert!(tags.insert(env.address.addr_tag), "duplicate addr_tag");
        }
    }

    #[test]
    fn store_delivers_only_matching_envelopes() {
        let bob = identity(1, 2);
        let carol = identity(7, 8);
        let mut store = InMemoryStore::new();

        send(&mut store, &bob.view_public(), b"bob-1").unwrap();
        send(&mut store, &carol.view_public(), b"carol-1").unwrap();
        send(&mut store, &bob.view_public(), b"bob-2").unwrap();

        let (cursor, bob_msgs) = receive(&store, bob.view(), 0);
        assert_eq!(bob_msgs, vec![b"bob-1".to_vec(), b"bob-2".to_vec()]);
        assert_eq!(cursor, 3);

        let (_, carol_msgs) = receive(&store, carol.view(), 0);
        assert_eq!(carol_msgs, vec![b"carol-1".to_vec()]);
    }

    #[test]
    fn cursor_advances_and_only_new_envelopes_return() {
        let bob = identity(1, 2);
        let mut store = InMemoryStore::new();
        send(&mut store, &bob.view_public(), b"first").unwrap();
        let (cursor, first) = receive(&store, bob.view(), 0);
        assert_eq!(first, vec![b"first".to_vec()]);

        send(&mut store, &bob.view_public(), b"second").unwrap();
        let (_, second) = receive(&store, bob.view(), cursor);
        assert_eq!(second, vec![b"second".to_vec()]);
    }
}
