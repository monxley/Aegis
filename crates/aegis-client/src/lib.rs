//! # aegis-client
//!
//! One identity, one API. `AegisClient` folds every layer of Aegis together so
//! an application deals with a single object instead of juggling an
//! [`aegis_identity::Identity`], an [`aegis_session::PrekeySecrets`], a set of
//! [`DoubleRatchet`](aegis_session::DoubleRatchet)s, and a mailbox by hand:
//!
//! - **identity & addressing** — one [`aegis_identity::Identity`] backs the
//!   shareable [`AegisId`], the view key that receives mail, the identity DH key
//!   used by the handshake, and the ML-DSA signing key that authenticates the
//!   published bundle (all derived from one seed, so they truly are one identity);
//! - **sessions** — PQXDH + the post-quantum Double Ratchet, established on first
//!   contact and reused thereafter, one per peer;
//! - **delivery** — sealed-sender envelopes over a blind [`MailboxStore`].
//!
//! ```
//! use aegis_client::AegisClient;
//! use aegis_mailbox::InMemoryStore;
//!
//! let mut alice = AegisClient::from_master_seed([1u8; 32]);
//! let mut bob = AegisClient::from_master_seed([2u8; 32]);
//! let mut relay = InMemoryStore::new();
//!
//! // Alice knows Bob's Aegis ID and prekey bundle (published out of band).
//! alice.start_conversation(&mut relay, &bob.aegis_id(), &bob.bundle(), b"hi bob").unwrap();
//!
//! // Bob scans the blind relay and reads it.
//! let got = bob.receive(&relay);
//! assert_eq!(got[0].message, b"hi bob");
//!
//! // Bob replies on the now-established session; Alice reads it.
//! bob.send(&mut relay, &got[0].from, b"hi alice").unwrap();
//! assert_eq!(alice.receive(&relay)[0].message, b"hi alice");
//! ```

mod wire;

use std::collections::HashMap;

use aegis_crypto::sha256;
use aegis_crypto::x25519::SecretKey;
use aegis_identity::{AegisId, Identity};
use aegis_mailbox::MailboxStore;
use aegis_session::{
    establish_initiator, establish_responder, DoubleRatchet, PrekeyBundle, PrekeySecrets,
};

use wire::Inner;

/// The secret seeds that deterministically define a client's keys. Derived from
/// one master seed so identity and prekey material share the same long-term
/// identity DH and signing keys.
struct Seeds {
    identity_dh: [u8; 32],
    view: [u8; 32],
    signing: [u8; 32],
    signed_prekey: [u8; 32],
    kem_d: [u8; 32],
    kem_z: [u8; 32],
    one_time: [u8; 32],
    ratchet_kem: [u8; 32],
}

fn derive(master: &[u8; 32], tag: &[u8]) -> [u8; 32] {
    let mut input = Vec::with_capacity(32 + tag.len());
    input.extend_from_slice(master);
    input.extend_from_slice(tag);
    sha256(&input)
}

impl Seeds {
    fn from_master(master: &[u8; 32]) -> Self {
        Seeds {
            identity_dh: derive(master, b"aegis/client/identity-dh"),
            view: derive(master, b"aegis/client/view"),
            signing: derive(master, b"aegis/client/signing"),
            signed_prekey: derive(master, b"aegis/client/signed-prekey"),
            kem_d: derive(master, b"aegis/client/kem-d"),
            kem_z: derive(master, b"aegis/client/kem-z"),
            one_time: derive(master, b"aegis/client/one-time"),
            ratchet_kem: derive(master, b"aegis/client/ratchet-kem"),
        }
    }

    /// Build a fresh `PrekeySecrets` (deterministic, so its public bundle is
    /// stable and it can back many responder sessions).
    fn prekeys(&self) -> PrekeySecrets {
        PrekeySecrets::from_seeds(
            self.identity_dh,
            self.signed_prekey,
            self.kem_d,
            self.kem_z,
            Some(self.one_time),
            self.signing,
            self.ratchet_kem,
        )
    }
}

/// A message received and decrypted for this client.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Received {
    /// The sender's Aegis ID (learned from the sealed envelope — the relay never
    /// saw it). Use it to [`send`](AegisClient::send) a reply.
    pub from: AegisId,
    /// The decrypted plaintext.
    pub message: Vec<u8>,
}

/// Errors from client operations.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ClientError {
    /// A peer's prekey bundle failed its own signature check.
    UnauthenticBundle,
    /// A peer's bundle does not match the Aegis ID it was presented with
    /// (wrong identity DH key or signing key) — a substitution / MITM.
    IdentityMismatch,
    /// No established session with this peer (call `start_conversation` first).
    NoSession,
    /// Session setup failed.
    Session,
    /// Message encryption failed (e.g. sending before the session is ready).
    Encrypt,
}

impl core::fmt::Display for ClientError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        let s = match self {
            ClientError::UnauthenticBundle => "prekey bundle signature did not verify",
            ClientError::IdentityMismatch => "bundle does not match the peer's Aegis ID",
            ClientError::NoSession => "no established session with this peer",
            ClientError::Session => "session setup failed",
            ClientError::Encrypt => "message encryption failed",
        };
        f.write_str(s)
    }
}

impl std::error::Error for ClientError {}

/// A full Aegis client: one identity, its sessions, and a mailbox scan cursor.
pub struct AegisClient {
    identity: Identity,
    seeds: Seeds,
    sessions: HashMap<[u8; 32], DoubleRatchet>,
    cursor: usize,
}

impl AegisClient {
    /// Create a client deterministically from a 32-byte master seed (all keys
    /// are derived from it). Use [`generate`](Self::generate) for a random one.
    pub fn from_master_seed(master: [u8; 32]) -> Self {
        let seeds = Seeds::from_master(&master);
        let identity = Identity::from_secret_bytes(seeds.identity_dh, seeds.view, seeds.signing);
        AegisClient {
            identity,
            seeds,
            sessions: HashMap::new(),
            cursor: 0,
        }
    }

    /// Create a client from OS randomness.
    pub fn generate() -> Self {
        let mut master = [0u8; 32];
        aegis_crypto::fill_random(&mut master);
        Self::from_master_seed(master)
    }

    /// This client's shareable Aegis ID (identity DH key, view key, and a
    /// commitment to the signing key).
    pub fn aegis_id(&self) -> AegisId {
        self.identity.aegis_id()
    }

    /// This client's signed prekey bundle, to publish so others can start a
    /// conversation while it is offline.
    pub fn bundle(&self) -> PrekeyBundle {
        self.seeds.prekeys().public_bundle()
    }

    /// Start a conversation with a peer: verify their bundle against their Aegis
    /// ID, run PQXDH, and send `message` as the first ratchet message through
    /// the relay. Establishes and stores the session.
    pub fn start_conversation(
        &mut self,
        store: &mut impl MailboxStore,
        peer: &AegisId,
        bundle: &PrekeyBundle,
        message: &[u8],
    ) -> Result<(), ClientError> {
        // Authenticate the bundle and bind it to this exact peer (G8).
        if !bundle.verify() {
            return Err(ClientError::UnauthenticBundle);
        }
        if bundle.identity_dh != peer.identity_dh_public()
            || !peer.verify_signing_key(&bundle.identity_signing_public)
        {
            return Err(ClientError::IdentityMismatch);
        }

        let identity_dh = SecretKey::from_bytes(self.seeds.identity_dh);
        let (initial, mut ratchet) =
            establish_initiator(&identity_dh, bundle).map_err(|_| ClientError::Session)?;
        let first = ratchet
            .encrypt(message, b"")
            .map_err(|_| ClientError::Encrypt)?;

        let inner = Inner::Handshake {
            sender: self.identity.aegis_id(),
            initial,
            first,
        };
        // Sealed-sender: the relay sees only a one-time address and ciphertext.
        aegis_mailbox::send(store, &peer.view_public(), &inner.encode())
            .map_err(|_| ClientError::Session)?;

        self.sessions.insert(peer.identity_dh_public(), ratchet);
        Ok(())
    }

    /// Send `message` on an already-established session with `peer`.
    pub fn send(
        &mut self,
        store: &mut impl MailboxStore,
        peer: &AegisId,
        message: &[u8],
    ) -> Result<(), ClientError> {
        let ratchet = self
            .sessions
            .get_mut(&peer.identity_dh_public())
            .ok_or(ClientError::NoSession)?;
        let message = ratchet
            .encrypt(message, b"")
            .map_err(|_| ClientError::Encrypt)?;
        let inner = Inner::Chat {
            sender: self.identity.aegis_id(),
            message,
        };
        aegis_mailbox::send(store, &peer.view_public(), &inner.encode())
            .map_err(|_| ClientError::Session)?;
        Ok(())
    }

    /// Scan the relay for new mail addressed to this client, decrypt it, and
    /// return the messages. New peers (handshakes) are established transparently;
    /// their sessions are stored so replies work. Envelopes for other recipients
    /// or that fail to decrypt are silently skipped.
    pub fn receive(&mut self, store: &impl MailboxStore) -> Vec<Received> {
        let (cursor, inners) = aegis_mailbox::receive(store, self.identity.view(), self.cursor);
        self.cursor = cursor;

        let mut out = Vec::new();
        for bytes in inners {
            let Some(inner) = Inner::decode(&bytes) else {
                continue;
            };
            match inner {
                Inner::Handshake {
                    sender,
                    initial,
                    first,
                } => {
                    // A fresh responder session against our (stable) bundle.
                    let Ok(mut ratchet) = establish_responder(self.seeds.prekeys(), &initial)
                    else {
                        continue;
                    };
                    let Ok(message) = ratchet.decrypt(&first, b"") else {
                        continue;
                    };
                    self.sessions.insert(sender.identity_dh_public(), ratchet);
                    out.push(Received {
                        from: sender,
                        message,
                    });
                }
                Inner::Chat { sender, message } => {
                    let key = sender.identity_dh_public();
                    let Some(ratchet) = self.sessions.get_mut(&key) else {
                        continue; // no session — cannot decrypt
                    };
                    if let Ok(plaintext) = ratchet.decrypt(&message, b"") {
                        out.push(Received {
                            from: sender,
                            message: plaintext,
                        });
                    }
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use aegis_mailbox::InMemoryStore;

    #[test]
    fn two_clients_hold_a_conversation() {
        let mut alice = AegisClient::from_master_seed([1u8; 32]);
        let mut bob = AegisClient::from_master_seed([2u8; 32]);
        let mut relay = InMemoryStore::new();

        alice
            .start_conversation(&mut relay, &bob.aegis_id(), &bob.bundle(), b"hi bob")
            .unwrap();

        let got = bob.receive(&relay);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].message, b"hi bob");
        assert_eq!(got[0].from, alice.aegis_id());

        // Bob replies on the established session.
        bob.send(&mut relay, &alice.aegis_id(), b"hi alice")
            .unwrap();
        let got = alice.receive(&relay);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].message, b"hi alice");
        assert_eq!(got[0].from, bob.aegis_id());
    }

    #[test]
    fn many_turns_flow_over_the_established_session() {
        let mut alice = AegisClient::from_master_seed([1u8; 32]);
        let mut bob = AegisClient::from_master_seed([2u8; 32]);
        let mut relay = InMemoryStore::new();

        alice
            .start_conversation(&mut relay, &bob.aegis_id(), &bob.bundle(), b"turn 0")
            .unwrap();
        assert_eq!(bob.receive(&relay)[0].message, b"turn 0");

        for i in 1..10u8 {
            bob.send(&mut relay, &alice.aegis_id(), &[i]).unwrap();
            assert_eq!(alice.receive(&relay)[0].message, vec![i]);
            alice
                .send(&mut relay, &bob.aegis_id(), &[i ^ 0xff])
                .unwrap();
            assert_eq!(bob.receive(&relay)[0].message, vec![i ^ 0xff]);
        }
    }

    #[test]
    fn a_third_client_sharing_the_relay_reads_nothing() {
        let mut alice = AegisClient::from_master_seed([1u8; 32]);
        let mut bob = AegisClient::from_master_seed([2u8; 32]);
        let mut carol = AegisClient::from_master_seed([3u8; 32]);
        let mut relay = InMemoryStore::new();

        alice
            .start_conversation(&mut relay, &bob.aegis_id(), &bob.bundle(), b"for bob")
            .unwrap();

        assert!(carol.receive(&relay).is_empty());
        assert_eq!(bob.receive(&relay).len(), 1);
    }

    #[test]
    fn bob_serves_several_initiators_from_one_bundle() {
        let mut bob = AegisClient::from_master_seed([2u8; 32]);
        let mut relay = InMemoryStore::new();
        let bob_id = bob.aegis_id();
        let bob_bundle = bob.bundle();

        for seed in 10..15u8 {
            let mut peer = AegisClient::from_master_seed([seed; 32]);
            peer.start_conversation(&mut relay, &bob_id, &bob_bundle, &[seed])
                .unwrap();
        }
        let got = bob.receive(&relay);
        assert_eq!(got.len(), 5);
        let mut msgs: Vec<u8> = got.iter().map(|r| r.message[0]).collect();
        msgs.sort_unstable();
        assert_eq!(msgs, (10..15).collect::<Vec<_>>());
    }

    #[test]
    fn sending_without_a_session_is_refused() {
        let mut alice = AegisClient::from_master_seed([1u8; 32]);
        let bob = AegisClient::from_master_seed([2u8; 32]);
        let mut relay = InMemoryStore::new();
        assert_eq!(
            alice.send(&mut relay, &bob.aegis_id(), b"hi"),
            Err(ClientError::NoSession)
        );
    }

    #[test]
    fn a_tampered_bundle_is_rejected() {
        let mut alice = AegisClient::from_master_seed([1u8; 32]);
        let bob = AegisClient::from_master_seed([2u8; 32]);
        let mut relay = InMemoryStore::new();

        let mut bundle = bob.bundle();
        bundle.signed_prekey[0] ^= 1;
        assert_eq!(
            alice.start_conversation(&mut relay, &bob.aegis_id(), &bundle, b"hi"),
            Err(ClientError::UnauthenticBundle)
        );
    }

    #[test]
    fn a_bundle_for_the_wrong_identity_is_rejected() {
        // A valid bundle, but presented under a different peer's Aegis ID.
        let mut alice = AegisClient::from_master_seed([1u8; 32]);
        let bob = AegisClient::from_master_seed([2u8; 32]);
        let mallory = AegisClient::from_master_seed([9u8; 32]);
        let mut relay = InMemoryStore::new();
        assert_eq!(
            alice.start_conversation(&mut relay, &bob.aegis_id(), &mallory.bundle(), b"hi"),
            Err(ClientError::IdentityMismatch)
        );
    }
}
