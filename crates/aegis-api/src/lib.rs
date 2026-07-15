//! # aegis-api — the app-facing Aegis engine
//!
//! Everything a user interface needs, behind one type. A UI (the Flutter app in
//! [`app/`](../../../app), bound through `flutter_rust_bridge`) never touches
//! keys or protocol state — it calls [`AegisApp`], which owns an
//! [`aegis_client::AegisClient`], a relay connection, a contact book, and the
//! conversation history.
//!
//! ```
//! use aegis_api::AegisApp;
//!
//! // Two users, each with a local demo relay of their own would not connect;
//! // here both share one in-memory relay to show the flow end to end.
//! let mut alice = AegisApp::create_in_memory(vec![1u8; 32]).unwrap();
//! let mut bob = AegisApp::create_in_memory(vec![2u8; 32]).unwrap();
//!
//! // They exchange Aegis IDs + bundles out of band (paste / QR), then add each
//! // other as contacts. (In a real deployment both share ONE relay; this doctest
//! // only exercises the identity/contact API, not delivery across two relays.)
//! alice.add_contact("Bob".into(), bob.my_aegis_id(), bob.my_bundle()).unwrap();
//! assert_eq!(alice.contacts()[0].name, "Bob");
//! assert!(alice.my_aegis_id().starts_with("aegis:"));
//! ```

mod wire;

use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

use aegis_client::{AegisClient, ClientError};
use aegis_identity::AegisId;
use aegis_mailbox::{Envelope, InMemoryStore, MailboxError, MailboxStore};
use aegis_relay::CiphraStore;

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Version tag on exported app state; bump on a format change.
const APP_STATE_VERSION: u8 = 1;

/// A little length-prefixing writer for [`AegisApp::export_state`].
struct StateWriter(Vec<u8>);

impl StateWriter {
    fn new() -> Self {
        StateWriter(Vec::new())
    }
    fn push_u8(&mut self, v: u8) {
        self.0.push(v);
    }
    fn push_u32(&mut self, v: u32) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    fn push_u64(&mut self, v: u64) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    fn push_bytes(&mut self, b: &[u8]) {
        self.push_u32(b.len() as u32);
        self.0.extend_from_slice(b);
    }
    fn into_bytes(self) -> Vec<u8> {
        self.0
    }
}

/// Parsed app state (see [`AegisApp::export_state`]).
struct AppState {
    client: Vec<u8>,
    contacts: Vec<StoredContact>,
    history: HashMap<String, Vec<ChatMessage>>,
}

/// A bounds-checked reader for [`AegisApp::restore_state`].
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
    fn u64(&mut self) -> Option<u64> {
        Some(u64::from_le_bytes(self.take(8)?.try_into().ok()?))
    }
    fn bytes(&mut self) -> Option<&'a [u8]> {
        let n = self.u32()? as usize;
        self.take(n)
    }
    fn string(&mut self) -> Option<String> {
        String::from_utf8(self.bytes()?.to_vec()).ok()
    }
}

fn parse_app_state(blob: &[u8]) -> Option<AppState> {
    let mut r = StateReader::new(blob);
    if r.u8()? != APP_STATE_VERSION {
        return None;
    }
    let client = r.bytes()?.to_vec();

    let contact_count = r.u32()? as usize;
    let mut contacts = Vec::with_capacity(contact_count);
    for _ in 0..contact_count {
        let name = r.string()?;
        let aegis_id = r.string()?;
        let bundle = r.bytes()?.to_vec();
        contacts.push(StoredContact {
            name,
            aegis_id,
            bundle,
        });
    }

    let convo_count = r.u32()? as usize;
    let mut history = HashMap::with_capacity(convo_count);
    for _ in 0..convo_count {
        let aegis_id = r.string()?;
        let msg_count = r.u32()? as usize;
        let mut msgs = Vec::with_capacity(msg_count);
        for _ in 0..msg_count {
            let from_me = r.u8()? != 0;
            let text = r.string()?;
            let timestamp_ms = r.u64()?;
            msgs.push(ChatMessage {
                from_me,
                text,
                timestamp_ms,
            });
        }
        history.insert(aegis_id, msgs);
    }
    Some(AppState {
        client,
        contacts,
        history,
    })
}

/// A contact in the address book.
#[derive(Clone, Debug)]
pub struct Contact {
    pub name: String,
    pub aegis_id: String,
}

/// One message in a conversation history.
#[derive(Clone, Debug)]
pub struct ChatMessage {
    pub from_me: bool,
    pub text: String,
    pub timestamp_ms: u64,
}

/// A message just delivered by [`AegisApp::poll`].
#[derive(Clone, Debug)]
pub struct IncomingMessage {
    pub from_aegis_id: String,
    /// The contact name, if the sender is in the address book.
    pub from_name: Option<String>,
    pub text: String,
}

/// Errors surfaced to the UI.
#[derive(Debug)]
pub enum AppError {
    /// The master seed was not 32 bytes.
    BadSeed,
    /// Could not reach the relay.
    Relay(String),
    /// The Aegis ID or bundle was malformed.
    BadContact,
    /// No such contact.
    UnknownContact,
    /// A protocol error (bad bundle, MITM, encryption failure, …).
    Protocol(String),
}

impl core::fmt::Display for AppError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            AppError::BadSeed => f.write_str("master seed must be 32 bytes"),
            AppError::Relay(e) => write!(f, "relay error: {e}"),
            AppError::BadContact => f.write_str("malformed Aegis ID or bundle"),
            AppError::UnknownContact => f.write_str("no such contact"),
            AppError::Protocol(e) => write!(f, "protocol error: {e}"),
        }
    }
}

impl std::error::Error for AppError {}

impl From<ClientError> for AppError {
    fn from(e: ClientError) -> Self {
        match e {
            ClientError::Relay => AppError::Relay("mailbox".into()),
            other => AppError::Protocol(other.to_string()),
        }
    }
}

/// The relay backing a client: a local in-memory store, or a live Ciphra server.
enum Store {
    Memory(InMemoryStore),
    Ciphra(Box<CiphraStore>),
}

impl MailboxStore for Store {
    fn put(&mut self, envelope: Envelope) -> Result<(), MailboxError> {
        match self {
            Store::Memory(s) => s.put(envelope),
            Store::Ciphra(s) => s.put(envelope),
        }
    }
    fn fetch_since(&self, cursor: usize) -> Result<(usize, Vec<Envelope>), MailboxError> {
        match self {
            Store::Memory(s) => s.fetch_since(cursor),
            Store::Ciphra(s) => s.fetch_since(cursor),
        }
    }
}

struct StoredContact {
    name: String,
    aegis_id: String,
    bundle: Vec<u8>,
}

/// The whole messenger behind one object: identity, relay, contacts, history.
pub struct AegisApp {
    client: AegisClient,
    store: Store,
    contacts: Vec<StoredContact>,
    history: HashMap<String, Vec<ChatMessage>>,
}

fn seed_array(seed: Vec<u8>) -> Result<[u8; 32], AppError> {
    seed.try_into().map_err(|_| AppError::BadSeed)
}

impl AegisApp {
    /// Create an app with a **local in-memory relay** (demos and tests).
    pub fn create_in_memory(master_seed: Vec<u8>) -> Result<AegisApp, AppError> {
        Ok(Self::from_parts(
            AegisClient::from_master_seed(seed_array(master_seed)?),
            Store::Memory(InMemoryStore::new()),
        ))
    }

    /// Create an app connected to a **live Ciphra blind server** at `relay_addr`
    /// (e.g. `"relay.example:5077"`). Trust-on-first-use for now.
    pub fn create_with_relay(
        master_seed: Vec<u8>,
        relay_addr: String,
    ) -> Result<AegisApp, AppError> {
        let client = AegisClient::from_master_seed(seed_array(master_seed)?);
        let store = CiphraStore::connect(relay_addr.as_str(), None)
            .map_err(|e| AppError::Relay(e.to_string()))?;
        Ok(Self::from_parts(client, Store::Ciphra(Box::new(store))))
    }

    fn from_parts(client: AegisClient, store: Store) -> Self {
        AegisApp {
            client,
            store,
            contacts: Vec::new(),
            history: HashMap::new(),
        }
    }

    /// This user's shareable Aegis ID (`aegis:…`).
    pub fn my_aegis_id(&self) -> String {
        self.client.aegis_id().encode()
    }

    /// This user's prekey bundle bytes, to publish next to the Aegis ID.
    pub fn my_bundle(&self) -> Vec<u8> {
        wire::encode_bundle(&self.client.bundle())
    }

    /// Add a contact from their Aegis ID and bundle bytes (both malformation
    /// checked). Adding an existing Aegis ID updates its name.
    pub fn add_contact(
        &mut self,
        name: String,
        aegis_id: String,
        bundle: Vec<u8>,
    ) -> Result<(), AppError> {
        AegisId::decode(&aegis_id).map_err(|_| AppError::BadContact)?;
        wire::decode_bundle(&bundle).ok_or(AppError::BadContact)?;
        if let Some(existing) = self.contacts.iter_mut().find(|c| c.aegis_id == aegis_id) {
            existing.name = name;
            existing.bundle = bundle;
        } else {
            self.contacts.push(StoredContact {
                name,
                aegis_id,
                bundle,
            });
        }
        Ok(())
    }

    /// The address book.
    pub fn contacts(&self) -> Vec<Contact> {
        self.contacts
            .iter()
            .map(|c| Contact {
                name: c.name.clone(),
                aegis_id: c.aegis_id.clone(),
            })
            .collect()
    }

    /// The conversation history with `aegis_id`, oldest first.
    pub fn history(&self, aegis_id: String) -> Vec<ChatMessage> {
        self.history.get(&aegis_id).cloned().unwrap_or_default()
    }

    /// Send `text` to the contact with `aegis_id`. Establishes the session on
    /// first message, then reuses it. Appends to the local history.
    pub fn send(&mut self, aegis_id: String, text: String) -> Result<(), AppError> {
        let contact = self
            .contacts
            .iter()
            .find(|c| c.aegis_id == aegis_id)
            .ok_or(AppError::UnknownContact)?;
        let peer = AegisId::decode(&contact.aegis_id).map_err(|_| AppError::BadContact)?;
        let bundle = wire::decode_bundle(&contact.bundle).ok_or(AppError::BadContact)?;

        match self.client.send(&mut self.store, &peer, text.as_bytes()) {
            Ok(()) => {}
            Err(ClientError::NoSession) => {
                self.client
                    .start_conversation(&mut self.store, &peer, &bundle, text.as_bytes())?;
            }
            Err(e) => return Err(e.into()),
        }

        self.history.entry(aegis_id).or_default().push(ChatMessage {
            from_me: true,
            text,
            timestamp_ms: now_ms(),
        });
        Ok(())
    }

    /// Snapshot everything worth keeping across a restart: the live sessions and
    /// mailbox cursor (from the client), the address book, and the conversation
    /// history. The blob holds ratchet secrets and plaintext history — persist it
    /// only in the app's private storage, never on the relay. Restore it into an
    /// app built from the **same master seed** with [`restore_state`](Self::restore_state).
    pub fn export_state(&self) -> Vec<u8> {
        let mut w = StateWriter::new();
        w.push_u8(APP_STATE_VERSION);
        w.push_bytes(&self.client.export_state());

        w.push_u32(self.contacts.len() as u32);
        for c in &self.contacts {
            w.push_bytes(c.name.as_bytes());
            w.push_bytes(c.aegis_id.as_bytes());
            w.push_bytes(&c.bundle);
        }

        w.push_u32(self.history.len() as u32);
        for (aegis_id, msgs) in &self.history {
            w.push_bytes(aegis_id.as_bytes());
            w.push_u32(msgs.len() as u32);
            for m in msgs {
                w.push_u8(m.from_me as u8);
                w.push_bytes(m.text.as_bytes());
                w.push_u64(m.timestamp_ms);
            }
        }
        w.into_bytes()
    }

    /// Restore state produced by [`export_state`](Self::export_state). Returns
    /// [`AppError::Protocol`] (leaving the app unchanged) if the blob is
    /// malformed or from an unknown version.
    pub fn restore_state(&mut self, blob: Vec<u8>) -> Result<(), AppError> {
        let parsed =
            parse_app_state(&blob).ok_or_else(|| AppError::Protocol("bad state".into()))?;
        if !self.client.import_state(&parsed.client) {
            return Err(AppError::Protocol("bad session state".into()));
        }
        self.contacts = parsed.contacts;
        self.history = parsed.history;
        Ok(())
    }

    /// Poll the relay for new messages, decrypt them, append to history, and
    /// return what arrived. Call this on a timer or a push wake-up.
    pub fn poll(&mut self) -> Result<Vec<IncomingMessage>, AppError> {
        let received = self.client.receive(&self.store)?;
        let mut out = Vec::with_capacity(received.len());
        for r in received {
            let aegis_id = r.from.encode();
            let text = String::from_utf8_lossy(&r.message).into_owned();
            let from_name = self
                .contacts
                .iter()
                .find(|c| c.aegis_id == aegis_id)
                .map(|c| c.name.clone());
            self.history
                .entry(aegis_id.clone())
                .or_default()
                .push(ChatMessage {
                    from_me: false,
                    text: text.clone(),
                    timestamp_ms: now_ms(),
                });
            out.push(IncomingMessage {
                from_aegis_id: aegis_id,
                from_name,
                text,
            });
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_and_contacts() {
        let mut alice = AegisApp::create_in_memory(vec![1u8; 32]).unwrap();
        let bob = AegisApp::create_in_memory(vec![2u8; 32]).unwrap();

        assert!(alice.my_aegis_id().starts_with("aegis:"));
        alice
            .add_contact("Bob".into(), bob.my_aegis_id(), bob.my_bundle())
            .unwrap();
        assert_eq!(alice.contacts().len(), 1);
        assert_eq!(alice.contacts()[0].name, "Bob");
    }

    #[test]
    fn bad_seed_and_bad_contact_are_rejected() {
        assert!(matches!(
            AegisApp::create_in_memory(vec![0u8; 8]),
            Err(AppError::BadSeed)
        ));
        let mut a = AegisApp::create_in_memory(vec![1u8; 32]).unwrap();
        assert!(matches!(
            a.add_contact("x".into(), "not-an-id".into(), vec![1, 2, 3]),
            Err(AppError::BadContact)
        ));
        assert!(matches!(
            a.send("aegis:whoever".into(), "hi".into()),
            Err(AppError::UnknownContact)
        ));
    }

    #[test]
    fn full_conversation_over_a_shared_relay() {
        // Alice and Bob share one in-memory relay (as they would share one
        // Ciphra server), so messages actually flow between them.
        let mut alice = AegisApp::create_in_memory(vec![1u8; 32]).unwrap();
        let mut bob = AegisApp::create_in_memory(vec![2u8; 32]).unwrap();
        alice
            .add_contact("Bob".into(), bob.my_aegis_id(), bob.my_bundle())
            .unwrap();
        bob.add_contact("Alice".into(), alice.my_aegis_id(), alice.my_bundle())
            .unwrap();

        // Move Alice's outgoing envelope into Bob's relay by hand (the two apps
        // hold separate in-memory stores; a real deployment shares one server).
        alice.send(bob.my_aegis_id(), "hi bob".into()).unwrap();
        transfer(&mut alice.store, &mut bob.store);
        let got = bob.poll().unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].text, "hi bob");
        assert_eq!(got[0].from_name.as_deref(), Some("Alice"));

        bob.send(alice.my_aegis_id(), "hi alice".into()).unwrap();
        transfer(&mut bob.store, &mut alice.store);
        let got = alice.poll().unwrap();
        assert_eq!(got[0].text, "hi alice");

        assert_eq!(alice.history(bob.my_aegis_id()).len(), 2); // sent + received
    }

    #[test]
    fn state_survives_a_restart() {
        // Alice talks to Bob, then "restarts": a fresh app from the same seed
        // that restores the saved blob must keep the contact, the history, and a
        // working session.
        let mut alice = AegisApp::create_in_memory(vec![1u8; 32]).unwrap();
        let mut bob = AegisApp::create_in_memory(vec![2u8; 32]).unwrap();
        alice
            .add_contact("Bob".into(), bob.my_aegis_id(), bob.my_bundle())
            .unwrap();
        bob.add_contact("Alice".into(), alice.my_aegis_id(), alice.my_bundle())
            .unwrap();

        alice.send(bob.my_aegis_id(), "hi bob".into()).unwrap();
        transfer(&mut alice.store, &mut bob.store);
        assert_eq!(bob.poll().unwrap().len(), 1);

        // Save Alice, drop her, rebuild from the seed, and restore.
        let blob = alice.export_state();
        let mut alice = AegisApp::create_in_memory(vec![1u8; 32]).unwrap();
        alice.restore_state(blob).unwrap();

        // The restored app remembers the contact and the history…
        assert_eq!(alice.contacts().len(), 1);
        assert_eq!(alice.contacts()[0].name, "Bob");
        assert_eq!(alice.history(bob.my_aegis_id()).len(), 1);

        // …and the session still works: Bob replies, Alice reads it.
        bob.send(alice.my_aegis_id(), "still connected".into())
            .unwrap();
        transfer(&mut bob.store, &mut alice.store);
        let got = alice.poll().unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].text, "still connected");
    }

    #[test]
    fn restore_rejects_garbage() {
        let mut a = AegisApp::create_in_memory(vec![1u8; 32]).unwrap();
        assert!(matches!(
            a.restore_state(vec![9, 9, 9]),
            Err(AppError::Protocol(_))
        ));
    }

    /// Test helper: copy every envelope from one in-memory store into another,
    /// standing in for a shared relay.
    fn transfer(from: &mut Store, to: &mut Store) {
        let (Store::Memory(from), Store::Memory(to)) = (from, to) else {
            unreachable!("test uses in-memory stores")
        };
        let (_, envelopes) = from.fetch_since(0).unwrap();
        for e in envelopes {
            to.put(e).unwrap();
        }
    }
}
