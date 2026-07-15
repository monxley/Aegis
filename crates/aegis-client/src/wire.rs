//! Wire encoding for the bytes carried *inside* a sealed mailbox envelope.
//!
//! A mailbox envelope transports opaque `inner` bytes (`aegis-mailbox`); this
//! module defines what an Aegis client puts there. Because the inner bytes are
//! sealed to the recipient, including the sender's Aegis ID here preserves
//! sealed-sender (the relay never sees it) while letting the recipient route the
//! message to the right session and reply.
//!
//! Two shapes:
//! - **Handshake** — first contact: the PQXDH initial message plus the first
//!   ratchet message, so the recipient can establish the session and read it.
//! - **Chat** — an ongoing ratchet message on an established session.

use aegis_identity::AegisId;
use aegis_session::{InitialMessage, Message};

/// The decoded inner payload of an envelope.
pub enum Inner {
    Handshake {
        sender: AegisId,
        initial: InitialMessage,
        first: Message,
    },
    Chat {
        sender: AegisId,
        message: Message,
    },
}

const TAG_HANDSHAKE: u8 = 1;
const TAG_CHAT: u8 = 2;

impl Inner {
    /// Serialize to the bytes placed inside an envelope.
    pub fn encode(&self) -> Vec<u8> {
        let mut w = Vec::new();
        match self {
            Inner::Handshake {
                sender,
                initial,
                first,
            } => {
                w.push(TAG_HANDSHAKE);
                put_aegis_id(&mut w, sender);
                put_initial(&mut w, initial);
                put_message(&mut w, first);
            }
            Inner::Chat { sender, message } => {
                w.push(TAG_CHAT);
                put_aegis_id(&mut w, sender);
                put_message(&mut w, message);
            }
        }
        w
    }

    /// Parse envelope inner bytes. Returns `None` on any malformation.
    pub fn decode(bytes: &[u8]) -> Option<Inner> {
        let mut r = Reader::new(bytes);
        let tag = r.u8()?;
        let sender = get_aegis_id(&mut r)?;
        match tag {
            TAG_HANDSHAKE => {
                let initial = get_initial(&mut r)?;
                let first = get_message(&mut r)?;
                Some(Inner::Handshake {
                    sender,
                    initial,
                    first,
                })
            }
            TAG_CHAT => {
                let message = get_message(&mut r)?;
                Some(Inner::Chat { sender, message })
            }
            _ => None,
        }
    }
}

// --- field codecs --------------------------------------------------------

fn put_lp(w: &mut Vec<u8>, bytes: &[u8]) {
    w.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
    w.extend_from_slice(bytes);
}

fn put_aegis_id(w: &mut Vec<u8>, id: &AegisId) {
    put_lp(w, id.encode().as_bytes());
}

fn put_initial(w: &mut Vec<u8>, im: &InitialMessage) {
    w.extend_from_slice(&im.identity_dh);
    w.extend_from_slice(&im.ephemeral);
    put_lp(w, &im.kem_ciphertext);
    w.push(im.used_one_time as u8);
}

fn put_message(w: &mut Vec<u8>, m: &Message) {
    put_lp(w, &m.header);
    put_lp(w, &m.ciphertext);
}

fn get_aegis_id(r: &mut Reader) -> Option<AegisId> {
    let bytes = r.lp()?;
    let s = std::str::from_utf8(bytes).ok()?;
    AegisId::decode(s).ok()
}

fn get_initial(r: &mut Reader) -> Option<InitialMessage> {
    let identity_dh = r.array32()?;
    let ephemeral = r.array32()?;
    let kem_ciphertext = r.lp()?.to_vec();
    let used_one_time = r.u8()? != 0;
    Some(InitialMessage {
        identity_dh,
        ephemeral,
        kem_ciphertext,
        used_one_time,
    })
}

fn get_message(r: &mut Reader) -> Option<Message> {
    let header = r.lp()?.to_vec();
    let ciphertext = r.lp()?.to_vec();
    Some(Message { header, ciphertext })
}

// --- reader --------------------------------------------------------------

struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Reader { buf, pos: 0 }
    }

    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let end = self.pos.checked_add(n)?;
        let slice = self.buf.get(self.pos..end)?;
        self.pos = end;
        Some(slice)
    }

    fn u8(&mut self) -> Option<u8> {
        Some(self.take(1)?[0])
    }

    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_le_bytes(self.take(4)?.try_into().ok()?))
    }

    fn lp(&mut self) -> Option<&'a [u8]> {
        let len = self.u32()? as usize;
        self.take(len)
    }

    fn array32(&mut self) -> Option<[u8; 32]> {
        self.take(32)?.try_into().ok()
    }
}
