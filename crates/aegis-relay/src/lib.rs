//! # aegis-relay
//!
//! A [`MailboxStore`] backed by a **live Ciphra blind server** — the seam that
//! turns Aegis's local mailbox into a real, deployable store-and-forward relay
//! (Layer 4a, `AEGIS_PROTOCOL.md` §5).
//!
//! [`CiphraStore`] wraps Ciphra's `RemoteStorage` client, which speaks the
//! blind-server protocol over a hybrid post-quantum channel (X25519 + ML-KEM-768):
//!
//! - **In transit** the connection is forward-secret and post-quantum, so a
//!   network observer sees nothing.
//! - **At rest** the server stores exactly what it is handed — and Aegis only
//!   ever hands it *already sealed* envelopes ([`aegis_mailbox`]), so the relay
//!   holds no keys and cannot read a message, a sender, or a recipient. It sees
//!   a stream of one-time addresses and opaque ciphertext.
//!
//! Envelopes are stored as key/value pairs under a fixed prefix, keyed by a
//! monotonic big-endian sequence number so a recipient can scan from a cursor.
//! Swapping [`aegis_mailbox::InMemoryStore`] for a `CiphraStore` is the only
//! change an application makes to go from a local demo to a networked relay —
//! the envelope format and the relay's blindness are identical.

use aegis_mailbox::{Envelope, MailboxError, MailboxStore};
use ciphra_net::RemoteStorage;

/// Key prefix under which mailbox envelopes are stored in the Ciphra database.
const PREFIX: &[u8] = b"aegis/mbox/";

/// A [`MailboxStore`] backed by a connection to a live Ciphra blind server.
pub struct CiphraStore {
    remote: RemoteStorage,
    next_seq: u64,
}

impl CiphraStore {
    /// Connect to a Ciphra blind server at `addr` and run its hybrid
    /// post-quantum handshake. Pass `Some(server_key)` to pin (authenticate)
    /// the server's static key; `None` is trust-on-first-use (still encrypted
    /// and post-quantum, but open to a MITM — matching Ciphra's own default).
    pub fn connect(
        addr: impl std::net::ToSocketAddrs,
        server_key: Option<[u8; 32]>,
    ) -> std::io::Result<Self> {
        let remote = RemoteStorage::connect(addr, server_key)?;
        // Resume the sequence past whatever this mailbox already holds.
        let next_seq = remote
            .scan_prefix(PREFIX)
            .map(|p| p.len() as u64)
            .unwrap_or(0);
        Ok(CiphraStore { remote, next_seq })
    }

    fn key(seq: u64) -> Vec<u8> {
        let mut key = PREFIX.to_vec();
        key.extend_from_slice(&seq.to_be_bytes());
        key
    }
}

impl MailboxStore for CiphraStore {
    fn put(&mut self, envelope: Envelope) -> Result<(), MailboxError> {
        let key = Self::key(self.next_seq);
        self.remote
            .put(&key, &envelope.to_bytes())
            .map_err(|e| MailboxError(e.to_string()))?;
        self.next_seq += 1;
        Ok(())
    }

    fn fetch_since(&self, cursor: usize) -> Result<(usize, Vec<Envelope>), MailboxError> {
        let mut pairs = self
            .remote
            .scan_prefix(PREFIX)
            .map_err(|e| MailboxError(e.to_string()))?;
        // Order by key (= sequence number) so the cursor is stable.
        pairs.sort_by(|a, b| a.0.cmp(&b.0));
        let total = pairs.len();
        let cursor = cursor.min(total);
        let envelopes = pairs[cursor..]
            .iter()
            .filter_map(|(_, value)| Envelope::from_bytes(value))
            .collect();
        Ok((total, envelopes))
    }
}
