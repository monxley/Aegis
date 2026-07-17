//! The flutter_rust_bridge surface: a thin, UI-friendly wrapper over
//! [`aegis_api::AegisApp`]. Every method returns `Result<_, String>` so the
//! Dart side gets a plain error message; all keys and protocol state stay in
//! Rust, behind the [`AegisEngine`] opaque handle.

use std::sync::Mutex;

use aegis_api::{
    AegisApp, ChatMessage as ApiChatMessage, Contact as ApiContact, NodeSummary as ApiNodeSummary,
};
use flutter_rust_bridge::frb;

/// A node in the gossiped directory (mirrored to Dart for the network view).
pub struct NodeSummary {
    pub id: String,
    pub mix_addr: String,
    pub provider_addr: Option<String>,
    pub is_provider: bool,
}

impl From<ApiNodeSummary> for NodeSummary {
    fn from(n: ApiNodeSummary) -> Self {
        NodeSummary {
            id: n.id,
            mix_addr: n.mix_addr,
            provider_addr: n.provider_addr,
            is_provider: n.is_provider,
        }
    }
}

/// Encrypt a master seed under an app-lock `password` (PBKDF2-HMAC-SHA256 +
/// ChaCha20-Poly1305). The returned blob is safe to persist on the device;
/// without the password the seed is unrecoverable, so no engine can be built and
/// the whole API stays inert — the lock guards the data, not just the screen.
/// Runs off the UI thread (the key derivation is deliberately slow).
pub fn seal_seed(password: String, seed: Vec<u8>) -> Vec<u8> {
    aegis_api::vault::seal_secret(&password, &seed)
}

/// Recover a seed sealed by [`seal_seed`]. Errors on a wrong password (a wrong
/// password and a corrupt blob are indistinguishable — no oracle).
pub fn open_seed(password: String, blob: Vec<u8>) -> Result<Vec<u8>, String> {
    aegis_api::vault::open_secret(&password, &blob).ok_or_else(|| "wrong password".to_string())
}

/// The 24-word recovery phrase for a 32-byte master seed — write it down to
/// back up your identity. Anyone with the phrase IS you, so keep it offline.
#[frb(sync)]
pub fn seed_to_phrase(seed: Vec<u8>) -> Result<String, String> {
    let seed: [u8; 32] = seed.try_into().map_err(|_| "seed must be 32 bytes".to_string())?;
    Ok(aegis_api::mnemonic::seed_to_phrase(&seed))
}

/// Recover the 32-byte seed from a 24-word phrase. Errors on a bad word count,
/// an unknown word, or a failed checksum (a typo).
#[frb(sync)]
pub fn phrase_to_seed(phrase: String) -> Result<Vec<u8>, String> {
    aegis_api::mnemonic::phrase_to_seed(&phrase)
        .map(|s| s.to_vec())
        .ok_or_else(|| "invalid recovery phrase (check the 24 words)".to_string())
}

/// Whether `latest` (a GitHub release tag) is a strictly newer version than
/// `current` (the running app version). Tolerates a leading `v` and pre-release
/// suffixes; returns false if either is unparseable.
#[frb(sync)]
pub fn is_newer_version(current: String, latest: String) -> bool {
    aegis_api::is_newer_version(&current, &latest)
}

/// Route all outbound traffic (mixnet + provider mailbox) through a SOCKS5
/// proxy. `proxy` is `host:port` (e.g. `127.0.0.1:9050` for Tor via Orbot);
/// `username`/`password` are optional SOCKS5 auth. Pass `None` for `proxy` to go
/// direct. Sync + process-wide — call before (re)building the engine so the very
/// first connection already uses it.
#[frb(sync)]
pub fn set_proxy(proxy: Option<String>, username: Option<String>, password: Option<String>) {
    aegis_api::set_proxy(proxy, username, password);
}

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
    /// Whether this chat is pinned to the top of the list.
    pub pinned: bool,
}

/// One message in a conversation (mirrored to Dart).
pub struct ChatMessage {
    pub from_me: bool,
    pub text: String,
    pub timestamp_ms: u64,
    /// Per-message id (matches a delivery/read receipt to its message).
    pub id: u64,
    /// For our own messages: 0 sent, 1 delivered, 2 read, 3 failed (kept locally
    /// and retried). Unused when received.
    pub status: u8,
    /// Unix-ms after which this disappearing message is gone (0 = never).
    pub expires_at_ms: u64,
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
            pinned: c.pinned,
        }
    }
}

impl From<ApiChatMessage> for ChatMessage {
    fn from(m: ApiChatMessage) -> Self {
        ChatMessage {
            from_me: m.from_me,
            text: m.text,
            timestamp_ms: m.timestamp_ms,
            id: m.id,
            status: m.status,
            expires_at_ms: m.expires_at_ms,
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

    /// The nodes this client knows from the gossiped directory (empty off the
    /// mixnet). Everyone's nodes show up here as the directory propagates.
    #[frb(sync)]
    pub fn network_nodes(&self) -> Vec<NodeSummary> {
        self.with(|app| app.network_nodes())
            .into_iter()
            .map(NodeSummary::from)
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
    /// the first message, then reuses it. The local copy is stored even if the
    /// network send fails (status "failed"), so a message is never lost.
    pub fn send(&self, aegis_id: String, text: String) -> Result<(), String> {
        self.with(|app| app.send(aegis_id, text))
            .map_err(|e| e.to_string())
    }

    /// Retry a message whose earlier send failed (status 3). No-op if `id` is not
    /// a failed outgoing message in this conversation.
    pub fn resend(&self, aegis_id: String, id: u64) -> Result<(), String> {
        self.with(|app| app.resend(aegis_id, id))
            .map_err(|e| e.to_string())
    }

    /// Pin or unpin a chat (pinned chats sort to the top of the list).
    pub fn set_pinned(&self, aegis_id: String, pinned: bool) -> Result<(), String> {
        self.with(|app| app.set_pinned(aegis_id, pinned))
            .map_err(|e| e.to_string())
    }

    /// Move a chat one place up (`up = true`) or down within its pinned group.
    pub fn move_chat(&self, aegis_id: String, up: bool) -> Result<(), String> {
        self.with(|app| app.move_chat(aegis_id, up))
            .map_err(|e| e.to_string())
    }

    /// Delete a conversation on this device only (contact + history + timer).
    pub fn delete_chat(&self, aegis_id: String) -> Result<(), String> {
        self.with(|app| app.delete_chat(aegis_id))
            .map_err(|e| e.to_string())
    }

    /// Delete a conversation for both sides: best-effort ask the peer to delete
    /// it too, then delete it here.
    pub fn delete_chat_for_both(&self, aegis_id: String) -> Result<(), String> {
        self.with(|app| app.delete_chat_for_both(aegis_id))
            .map_err(|e| e.to_string())
    }

    /// Mark the conversation with `aegis_id` as read — sends read receipts for
    /// the messages received in it, so the sender's copies show as read. Call
    /// when the user opens the chat.
    pub fn mark_read(&self, aegis_id: String) -> Result<(), String> {
        self.with(|app| app.mark_read(aegis_id))
            .map_err(|e| e.to_string())
    }

    /// The disappearing-message lifetime for a conversation, in seconds (0 =
    /// off).
    #[frb(sync)]
    pub fn disappearing_secs(&self, aegis_id: String) -> u32 {
        self.with(|app| app.disappearing_secs(aegis_id))
    }

    /// Set the disappearing-message timer for a conversation (`secs` 0 = off) and
    /// sync it to the peer. Messages sent after this expire on both sides.
    pub fn set_disappearing(&self, aegis_id: String, secs: u32) -> Result<(), String> {
        self.with(|app| app.set_disappearing(aegis_id, secs))
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
