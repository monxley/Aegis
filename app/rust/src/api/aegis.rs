//! The flutter_rust_bridge surface: a thin, UI-friendly wrapper over
//! [`aegis_api::AegisApp`]. Every method returns `Result<_, String>` so the
//! Dart side gets a plain error message; all keys and protocol state stay in
//! Rust, behind the [`AegisEngine`] opaque handle.

use std::sync::Mutex;

use aegis_api::{AegisApp, ChatMessage as ApiChatMessage, Contact as ApiContact};
use flutter_rust_bridge::frb;

/// A running opt-in mix node (returned by [`start_forwarder_node`]).
pub struct NodeInfo {
    pub address: String,
    pub node_id: String,
}

/// Turn this device into an **opt-in mix forwarder** that carries others' onion
/// traffic (it runs no mailbox). Good as a default on desktop/Linux; on Android
/// enable only on Wi-Fi + power. Uses a fresh identity unlinked to the Aegis ID.
/// `listen` e.g. `"0.0.0.0:0"`; `delay_rate` `None` for no Loopix delay.
pub fn start_forwarder_node(
    bootstrap: Vec<String>,
    listen: String,
    delay_rate: Option<f64>,
) -> Result<NodeInfo, String> {
    let handle = aegis_api::run_forwarder_node(bootstrap, listen, delay_rate)
        .map_err(|e| e.to_string())?;
    Ok(NodeInfo {
        address: handle.address,
        node_id: handle.node_id,
    })
}

/// A contact in the address book (mirrored to Dart).
pub struct Contact {
    pub name: String,
    pub aegis_id: String,
}

/// One message in a conversation (mirrored to Dart).
pub struct ChatMessage {
    pub from_me: bool,
    pub text: String,
    pub timestamp_ms: u64,
}

/// A message just delivered by [`AegisEngine::poll`].
pub struct IncomingMessage {
    pub from_aegis_id: String,
    pub from_name: Option<String>,
    pub text: String,
}

impl From<ApiContact> for Contact {
    fn from(c: ApiContact) -> Self {
        Contact {
            name: c.name,
            aegis_id: c.aegis_id,
        }
    }
}

impl From<ApiChatMessage> for ChatMessage {
    fn from(m: ApiChatMessage) -> Self {
        ChatMessage {
            from_me: m.from_me,
            text: m.text,
            timestamp_ms: m.timestamp_ms,
        }
    }
}

/// The whole messenger behind one opaque handle. The Dart side holds this and
/// calls into it; it never sees a key.
#[frb(opaque)]
pub struct AegisEngine {
    inner: Mutex<AegisApp>,
}

impl AegisEngine {
    /// Create an engine with a **local in-memory relay** (demos, first run
    /// without a server). `master_seed` must be 32 bytes.
    #[frb(sync)]
    pub fn new_in_memory(master_seed: Vec<u8>) -> Result<AegisEngine, String> {
        let app = AegisApp::create_in_memory(master_seed).map_err(|e| e.to_string())?;
        Ok(AegisEngine {
            inner: Mutex::new(app),
        })
    }

    /// Create an engine connected to a **live Ciphra blind server** at
    /// `relay_addr` (e.g. `"relay.example:5077"`). `master_seed` must be 32
    /// bytes. Trust-on-first-use for now.
    pub fn new_with_relay(master_seed: Vec<u8>, relay_addr: String) -> Result<AegisEngine, String> {
        let app = AegisApp::create_with_relay(master_seed, relay_addr).map_err(|e| e.to_string())?;
        Ok(AegisEngine {
            inner: Mutex::new(app),
        })
    }

    /// Create an engine that **auto-discovers the mixnet** from one or more
    /// `bootstrap` node addresses and onion-routes every send through it — the
    /// zero-setup, anonymous path. `master_seed` must be 32 bytes.
    pub fn new_on_network(
        master_seed: Vec<u8>,
        bootstrap: Vec<String>,
    ) -> Result<AegisEngine, String> {
        let app = AegisApp::create_on_network(master_seed, bootstrap).map_err(|e| e.to_string())?;
        Ok(AegisEngine {
            inner: Mutex::new(app),
        })
    }

    /// Like [`new_on_network`] but with **anonymous receive**: this device runs a
    /// reachable mix node (bound at `node_listen`, e.g. `"0.0.0.0:0"`) and polls
    /// its provider *through the mixnet* with single-use reply blocks, so the
    /// provider never learns who is polling. Use on a reachable device
    /// (desktop/Linux, or a phone with a forwarded port).
    pub fn new_on_network_with_receive(
        master_seed: Vec<u8>,
        bootstrap: Vec<String>,
        node_listen: String,
    ) -> Result<AegisEngine, String> {
        let app = AegisApp::create_on_network_with_receive(master_seed, bootstrap, node_listen)
            .map_err(|e| e.to_string())?;
        Ok(AegisEngine {
            inner: Mutex::new(app),
        })
    }

    fn with<T>(&self, f: impl FnOnce(&mut AegisApp) -> T) -> T {
        let mut guard = self.inner.lock().expect("engine mutex poisoned");
        f(&mut guard)
    }

    /// This user's shareable Aegis ID (`aegis:…`).
    #[frb(sync)]
    pub fn my_aegis_id(&self) -> String {
        self.with(|app| app.my_aegis_id())
    }

    /// This user's prekey bundle bytes, to publish next to the Aegis ID
    /// (paste / QR).
    #[frb(sync)]
    pub fn my_bundle(&self) -> Vec<u8> {
        self.with(|app| app.my_bundle())
    }

    /// Add a contact from their Aegis ID and bundle bytes. Adding an existing
    /// Aegis ID updates its name.
    #[frb(sync)]
    pub fn add_contact(
        &self,
        name: String,
        aegis_id: String,
        bundle: Vec<u8>,
    ) -> Result<(), String> {
        self.with(|app| app.add_contact(name, aegis_id, bundle))
            .map_err(|e| e.to_string())
    }

    /// The address book.
    #[frb(sync)]
    pub fn contacts(&self) -> Vec<Contact> {
        self.with(|app| app.contacts())
            .into_iter()
            .map(Contact::from)
            .collect()
    }

    /// The safety number shared with `aegis_id` — compare it with the contact
    /// out of band to rule out a key substitution (MITM).
    #[frb(sync)]
    pub fn safety_number(&self, aegis_id: String) -> Result<String, String> {
        self.with(|app| app.safety_number(aegis_id))
            .map_err(|e| e.to_string())
    }

    /// The conversation history with `aegis_id`, oldest first.
    #[frb(sync)]
    pub fn history(&self, aegis_id: String) -> Vec<ChatMessage> {
        self.with(|app| app.history(aegis_id))
            .into_iter()
            .map(ChatMessage::from)
            .collect()
    }

    /// Send `text` to the contact with `aegis_id`. Establishes the session on
    /// the first message, then reuses it.
    pub fn send(&self, aegis_id: String, text: String) -> Result<(), String> {
        self.with(|app| app.send(aegis_id, text))
            .map_err(|e| e.to_string())
    }

    /// Snapshot sessions, contacts, and history so a restart resumes the
    /// conversation. Persist the blob in the app's private storage (never on the
    /// relay); restore it into an engine built from the same seed.
    #[frb(sync)]
    pub fn export_state(&self) -> Vec<u8> {
        self.with(|app| app.export_state())
    }

    /// Restore state from [`export_state`]. Errors (leaving the engine
    /// unchanged) if the blob is malformed or from an unknown version.
    #[frb(sync)]
    pub fn restore_state(&self, blob: Vec<u8>) -> Result<(), String> {
        self.with(|app| app.restore_state(blob))
            .map_err(|e| e.to_string())
    }

    /// Emit one cover-traffic packet into the mixnet (a decoy), so an observer
    /// can't tell when this device is actually sending. Call on a Poisson
    /// schedule; no-op unless on the mixnet.
    pub fn send_cover(&self) -> Result<(), String> {
        self.with(|app| app.send_cover()).map_err(|e| e.to_string())
    }

    /// Poll the relay for new messages, decrypt them, append to history, and
    /// return what arrived. Call on a timer or a push wake-up.
    pub fn poll(&self) -> Result<Vec<IncomingMessage>, String> {
        let received = self.with(|app| app.poll()).map_err(|e| e.to_string())?;
        Ok(received
            .into_iter()
            .map(|m| IncomingMessage {
                from_aegis_id: m.from_aegis_id,
                from_name: m.from_name,
                text: m.text,
            })
            .collect())
    }
}
