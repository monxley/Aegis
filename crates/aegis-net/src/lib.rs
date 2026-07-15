//! # aegis-net — Phase 3
//!
//! Network-layer anonymity for Aegis (Layer 4b of
//! [`AEGIS_PROTOCOL.md`](../../../AEGIS_PROTOCOL.md) §6), with the exact
//! mathematics in [`docs/CRYPTO_MATH.md`](../../../docs/CRYPTO_MATH.md) §5.
//!
//! This crate implements **Sphinx** onion routing: a sender wraps a message in
//! fixed-size layers routed through a path of mixes so each hop learns only its
//! predecessor and successor — never the origin, the destination, or the
//! payload — and every hop sees a packet of identical size. It is built from
//! the primitives in [`aegis_crypto`] (X25519 for the DH/blinding chain,
//! ChaCha20 as the header/payload stream cipher, HMAC-SHA256 for the per-hop
//! header MAC): Sphinx needs no new primitives.
//!
//! The Poisson mixing and cover traffic of Loopix (§6.2) — which hide *timing*
//! on top of the *routing* Sphinx hides — are the planned next increment; this
//! crate is the packet format they schedule.
//!
//! ```
//! use aegis_net::{MixNode, SphinxPacket, ProcessedPacket, DEST_MARKER};
//!
//! // Three mixes, each with a keypair; the sender knows their public keys.
//! let mixes: Vec<MixNode> = (0..3).map(|i| MixNode::from_seed(&[i as u8; 32])).collect();
//! let path: Vec<_> = mixes.iter().map(|m| m.public_hop()).collect();
//!
//! // Wrap a message for the path.
//! let packet = SphinxPacket::seal(&path, b"meet at dawn").unwrap();
//!
//! // Each hop peels one layer until the exit recovers the payload.
//! let mut pkt = packet;
//! for (i, mix) in mixes.iter().enumerate() {
//!     match mix.process(&pkt).unwrap() {
//!         ProcessedPacket::Forward { next, packet } => {
//!             assert_ne!(next, DEST_MARKER);
//!             assert!(i < 2);
//!             pkt = *packet;
//!         }
//!         ProcessedPacket::Deliver { payload } => {
//!             assert_eq!(i, 2);
//!             assert_eq!(&payload, b"meet at dawn");
//!         }
//!     }
//! }
//! ```

pub mod loopix;
pub mod rng;

use aegis_crypto::x25519::SecretKey;
use aegis_crypto::{chacha20, hmac_sha256, sha256};

/// Length of a mix node's network id / address.
pub const NODE_ID_LEN: usize = 16;
/// Length of a per-hop header MAC (truncated HMAC-SHA256).
pub const MAC_LEN: usize = 16;
/// Per-hop routing block: next-hop id + next-hop MAC.
const HOP_META: usize = NODE_ID_LEN + MAC_LEN;
/// Maximum path length (the packet is padded to this regardless of actual hops).
pub const MAX_HOPS: usize = 5;
/// Fixed routing-header length.
const BETA_LEN: usize = MAX_HOPS * HOP_META;
/// Fixed payload length. Messages are padded to this; longer messages are
/// rejected by [`SphinxPacket::seal`]. Sized to carry a full Aegis sealed
/// envelope (a PQXDH handshake with an ML-KEM prekey is ~3.7 KB) so a whole
/// message rides one fixed-size packet; every packet is identical in size
/// regardless of the message, which is the point.
pub const PAYLOAD_LEN: usize = 4096;

/// The fixed on-the-wire size of a serialized [`SphinxPacket`]: `alpha (32) ‖
/// beta (BETA_LEN) ‖ gamma (MAC_LEN) ‖ delta (PAYLOAD_LEN)`. Every packet is
/// exactly this many bytes at every hop.
pub const PACKET_LEN: usize = 32 + BETA_LEN + MAC_LEN + PAYLOAD_LEN;

/// Reserved next-hop id meaning "you are the exit — the payload is yours".
pub const DEST_MARKER: [u8; NODE_ID_LEN] = [0xff; NODE_ID_LEN];

const NONCE: [u8; 12] = [0u8; 12];

/// A mix node: an X25519 keypair plus its network id.
pub struct MixNode {
    secret: SecretKey,
    id: [u8; NODE_ID_LEN],
    public: [u8; 32],
}

/// The public description of a mix a sender routes through.
#[derive(Clone, Copy, Debug)]
pub struct Hop {
    /// The mix's network id (what the previous hop forwards to).
    pub id: [u8; NODE_ID_LEN],
    /// The mix's X25519 public key.
    pub public: [u8; 32],
}

impl MixNode {
    /// Deterministically derive a mix node from a 32-byte seed. The node id is
    /// `SHA-256(public)[..16]`.
    pub fn from_seed(seed: &[u8; 32]) -> Self {
        let secret = SecretKey::from_bytes(*seed);
        let public = secret.public_key();
        let mut id = [0u8; NODE_ID_LEN];
        id.copy_from_slice(&sha256(&public)[..NODE_ID_LEN]);
        MixNode { secret, id, public }
    }

    /// The public hop description to hand to senders.
    pub fn public_hop(&self) -> Hop {
        Hop {
            id: self.id,
            public: self.public,
        }
    }

    /// Process one Sphinx packet: verify its MAC, peel one layer, and either
    /// forward to the next hop or deliver the payload if this is the exit.
    pub fn process(&self, packet: &SphinxPacket) -> Result<ProcessedPacket, SphinxError> {
        let s = self.secret.diffie_hellman(&packet.alpha);
        if s == [0u8; 32] {
            return Err(SphinxError::Degenerate);
        }

        // Verify the header MAC before touching anything else.
        let expected = truncated_mac(&mu_key(&s), &packet.beta);
        if expected != packet.gamma {
            return Err(SphinxError::BadMac);
        }

        // Peel the routing header: B = (beta ‖ 0^HOP_META) XOR PRG(rho).
        let mut b = [0u8; BETA_LEN + HOP_META];
        b[..BETA_LEN].copy_from_slice(&packet.beta);
        xor_prg(&rho_key(&s), &mut b);

        let mut next_id = [0u8; NODE_ID_LEN];
        next_id.copy_from_slice(&b[..NODE_ID_LEN]);
        let mut next_gamma = [0u8; MAC_LEN];
        next_gamma.copy_from_slice(&b[NODE_ID_LEN..HOP_META]);
        let mut next_beta = [0u8; BETA_LEN];
        next_beta.copy_from_slice(&b[HOP_META..]);

        // Peel one payload layer.
        let mut payload = packet.delta;
        lioness_decrypt(&pi_key(&s), &mut payload);

        if next_id == DEST_MARKER {
            return Ok(ProcessedPacket::Deliver {
                payload: unpad(&payload)?,
            });
        }

        // Blind the group element for the next hop.
        let b_scalar = blind(&packet.alpha, &s);
        let next_alpha = SecretKey::from_bytes(b_scalar).diffie_hellman(&packet.alpha);

        Ok(ProcessedPacket::Forward {
            next: next_id,
            packet: Box::new(SphinxPacket {
                alpha: next_alpha,
                beta: next_beta,
                gamma: next_gamma,
                delta: payload,
            }),
        })
    }
}

/// The result of a mix processing a packet.
pub enum ProcessedPacket {
    /// Forward `packet` to the mix with id `next`. Boxed because a Sphinx
    /// packet is ~1.2 KB and dwarfs the `Deliver` variant.
    Forward {
        next: [u8; NODE_ID_LEN],
        packet: Box<SphinxPacket>,
    },
    /// This mix is the exit; `payload` is the delivered message.
    Deliver { payload: Vec<u8> },
}

/// A fixed-size Sphinx packet. `alpha`, `beta` and `delta` all have the same
/// size at every hop, so a packet's position on its path does not leak.
#[derive(Clone)]
pub struct SphinxPacket {
    /// Group element carrying the (blinded) ephemeral key.
    pub alpha: [u8; 32],
    /// Encrypted routing header.
    pub beta: [u8; BETA_LEN],
    /// Header MAC for this hop.
    pub gamma: [u8; MAC_LEN],
    /// Onion-encrypted payload.
    pub delta: [u8; PAYLOAD_LEN],
}

/// Errors from Sphinx processing / sealing.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SphinxError {
    /// Empty path, or path longer than [`MAX_HOPS`].
    BadPathLength,
    /// The message did not fit in [`PAYLOAD_LEN`] after padding.
    MessageTooLong,
    /// The header MAC did not verify — tampered or not addressed to this mix.
    BadMac,
    /// The X25519 shared secret was the all-zero point (small-order input).
    Degenerate,
    /// The delivered payload padding was malformed.
    BadPadding,
}

impl core::fmt::Display for SphinxError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        let s = match self {
            SphinxError::BadPathLength => "path must be 1..=MAX_HOPS mixes",
            SphinxError::MessageTooLong => "message too long for the fixed payload",
            SphinxError::BadMac => "header MAC verification failed",
            SphinxError::Degenerate => "degenerate (all-zero) shared secret",
            SphinxError::BadPadding => "malformed payload padding",
        };
        f.write_str(s)
    }
}

impl std::error::Error for SphinxError {}

impl SphinxPacket {
    /// Seal `message` into a Sphinx packet routed through `path` (an ordered
    /// list of mixes, the last of which is the exit that recovers the payload).
    pub fn seal(path: &[Hop], message: &[u8]) -> Result<SphinxPacket, SphinxError> {
        let nu = path.len();
        if nu == 0 || nu > MAX_HOPS {
            return Err(SphinxError::BadPathLength);
        }

        // Ephemeral scalar and the blinding chain: shared secrets per hop.
        let mut ephemeral = [0u8; 32];
        aegis_crypto::fill_random(&mut ephemeral);
        let (alphas, shared) = blinding_chain(&ephemeral, path);

        // Filler that keeps the header fixed-size as each hop shifts it.
        let filler = filler(&shared);

        // --- routing header, built from the exit inward ---
        // Exit hop: its next-hop id is the DEST marker; its beta is
        // (DEST ‖ pad) XOR PRG, with the filler occupying the shifted tail.
        let last = nu - 1;
        let mut beta = [0u8; BETA_LEN];
        let prefix_len = BETA_LEN - (nu - 1) * HOP_META;
        let mut prefix = vec![0u8; prefix_len];
        prefix[..NODE_ID_LEN].copy_from_slice(&DEST_MARKER);
        let stream = prg(&rho_key(&shared[last]));
        for i in 0..prefix_len {
            beta[i] = prefix[i] ^ stream[i];
        }
        beta[prefix_len..].copy_from_slice(&filler);
        let mut gamma = truncated_mac(&mu_key(&shared[last]), &beta);

        // Wrap outward through the interior hops.
        for i in (0..last).rev() {
            // plaintext prefix = next_id ‖ next_gamma ‖ beta[..BETA_LEN-HOP_META]
            let mut plaintext = [0u8; BETA_LEN];
            plaintext[..NODE_ID_LEN].copy_from_slice(&path[i + 1].id);
            plaintext[NODE_ID_LEN..HOP_META].copy_from_slice(&gamma);
            plaintext[HOP_META..].copy_from_slice(&beta[..BETA_LEN - HOP_META]);

            let stream = prg(&rho_key(&shared[i]));
            for j in 0..BETA_LEN {
                beta[j] = plaintext[j] ^ stream[j];
            }
            gamma = truncated_mac(&mu_key(&shared[i]), &beta);
        }

        // --- payload onion: pad, then wrap each hop's LIONESS layer (exit
        // first, so hop 0's layer is outermost and peeled first) ---
        let mut delta = pad(message)?;
        for i in (0..nu).rev() {
            lioness_encrypt(&pi_key(&shared[i]), &mut delta);
        }

        Ok(SphinxPacket {
            alpha: alphas[0],
            beta,
            gamma,
            delta,
        })
    }

    /// Serialize to the fixed [`PACKET_LEN`] wire form so a mix can forward it to
    /// the next hop. The layout — `alpha ‖ beta ‖ gamma ‖ delta` — is the same
    /// length at every hop, so a packet's position on its path never leaks.
    pub fn to_bytes(&self) -> [u8; PACKET_LEN] {
        let mut out = [0u8; PACKET_LEN];
        let mut o = 0;
        out[o..o + 32].copy_from_slice(&self.alpha);
        o += 32;
        out[o..o + BETA_LEN].copy_from_slice(&self.beta);
        o += BETA_LEN;
        out[o..o + MAC_LEN].copy_from_slice(&self.gamma);
        o += MAC_LEN;
        out[o..o + PAYLOAD_LEN].copy_from_slice(&self.delta);
        out
    }

    /// Parse the fixed-size wire form from [`to_bytes`](Self::to_bytes). Returns
    /// `None` if `bytes` is not exactly [`PACKET_LEN`].
    pub fn from_bytes(bytes: &[u8]) -> Option<SphinxPacket> {
        if bytes.len() != PACKET_LEN {
            return None;
        }
        let mut o = 0;
        let mut alpha = [0u8; 32];
        alpha.copy_from_slice(&bytes[o..o + 32]);
        o += 32;
        let mut beta = [0u8; BETA_LEN];
        beta.copy_from_slice(&bytes[o..o + BETA_LEN]);
        o += BETA_LEN;
        let mut gamma = [0u8; MAC_LEN];
        gamma.copy_from_slice(&bytes[o..o + MAC_LEN]);
        o += MAC_LEN;
        let mut delta = [0u8; PAYLOAD_LEN];
        delta.copy_from_slice(&bytes[o..o + PAYLOAD_LEN]);
        Some(SphinxPacket {
            alpha,
            beta,
            gamma,
            delta,
        })
    }
}

// --- blinding chain and filler (CRYPTO_MATH §5.2, §5.4) -------------------

/// Compute `alpha_i` and the per-hop shared secret `s_i` for the whole path.
fn blinding_chain(ephemeral: &[u8; 32], path: &[Hop]) -> (Vec<[u8; 32]>, Vec<[u8; 32]>) {
    let mut alphas = Vec::with_capacity(path.len());
    let mut shared = Vec::with_capacity(path.len());
    let mut blindings: Vec<[u8; 32]> = Vec::new();

    let mut alpha = SecretKey::from_bytes(*ephemeral).public_key();
    for hop in path {
        alphas.push(alpha);
        // s_i = y_i^{x0 · b_0 · … · b_{i-1}}, computed incrementally.
        let mut s = SecretKey::from_bytes(*ephemeral).diffie_hellman(&hop.public);
        for b in &blindings {
            s = SecretKey::from_bytes(*b).diffie_hellman(&s);
        }
        shared.push(s);
        let b = blind(&alpha, &s);
        blindings.push(b);
        alpha = SecretKey::from_bytes(b).diffie_hellman(&alpha);
    }
    (alphas, shared)
}

/// The filler string (length `(ν-1)·HOP_META`) that the shifted-out padding of
/// each hop reconstructs, so every header stays `BETA_LEN` bytes. Interior hop
/// `i` contributes `PRG(ρ_i)[BETA_LEN - i·HOP_META .. BETA_LEN + HOP_META]`
/// (length `(i+1)·HOP_META`), accumulated into a fixed buffer — this is exactly
/// the value each hop's revealed tail keystream must reconstruct.
fn filler(shared: &[[u8; 32]]) -> Vec<u8> {
    let nu = shared.len();
    let mut filler = vec![0u8; (nu - 1) * HOP_META];
    for (i, s) in shared.iter().enumerate().take(nu - 1) {
        let stream = prg(&rho_key(s));
        let start = BETA_LEN - i * HOP_META;
        let piece_len = (i + 1) * HOP_META;
        for j in 0..piece_len {
            filler[j] ^= stream[start + j];
        }
    }
    filler
}

// --- per-hop key derivation (CRYPTO_MATH §5.1) ---------------------------

fn derive(context: &[u8], s: &[u8; 32]) -> [u8; 32] {
    let mut input = Vec::with_capacity(context.len() + 32);
    input.extend_from_slice(context);
    input.extend_from_slice(s);
    sha256(&input)
}

fn rho_key(s: &[u8; 32]) -> [u8; 32] {
    derive(b"aegis/sphinx/rho", s)
}
fn mu_key(s: &[u8; 32]) -> [u8; 32] {
    derive(b"aegis/sphinx/mu", s)
}
fn pi_key(s: &[u8; 32]) -> [u8; 32] {
    derive(b"aegis/sphinx/pi", s)
}

/// Blinding scalar `b_i = H(alpha_i ‖ s_i)` (X25519 clamps it on use).
fn blind(alpha: &[u8; 32], s: &[u8; 32]) -> [u8; 32] {
    let mut input = Vec::with_capacity(16 + 64);
    input.extend_from_slice(b"aegis/sphinx/blind");
    input.extend_from_slice(alpha);
    input.extend_from_slice(s);
    sha256(&input)
}

fn truncated_mac(key: &[u8; 32], data: &[u8]) -> [u8; MAC_LEN] {
    let full = hmac_sha256(key, data);
    let mut mac = [0u8; MAC_LEN];
    mac.copy_from_slice(&full[..MAC_LEN]);
    mac
}

/// ChaCha20 keystream of length `BETA_LEN + HOP_META` for the header.
fn prg(key: &[u8; 32]) -> [u8; BETA_LEN + HOP_META] {
    let mut buf = [0u8; BETA_LEN + HOP_META];
    chacha20::xor_stream(key, &NONCE, 0, &mut buf);
    buf
}

/// XOR a header buffer with the header PRG keystream.
fn xor_prg(key: &[u8; 32], data: &mut [u8; BETA_LEN + HOP_META]) {
    let ks = prg(key);
    for (b, k) in data.iter_mut().zip(ks.iter()) {
        *b ^= k;
    }
}

// --- LIONESS wide-block cipher for the payload ---------------------------
//
// The payload must be non-malleable: with a plain stream cipher a one-bit flip
// propagates unchanged to the exit, enabling a *tagging attack* (mark a packet
// at the entry, recognize it at the exit → deanonymization). The header MAC
// protects the header but not the payload, so the payload itself must be a
// pseudo-random permutation where any change scrambles the whole block.
//
// LIONESS (Anderson–Biham) builds exactly that from a stream cipher `S` and a
// keyed hash `H` over four unbalanced-Feistel rounds. The block splits into a
// key-sized left half `L` (32 B) and the rest `R`:
//
//   R ^= S(L ^ k1);  L ^= H(k2, R);  R ^= S(L ^ k3);  L ^= H(k4, R)
//
// Decryption runs the rounds in reverse. Each hop encrypts one layer; a single
// altered byte anywhere makes the delivered block uniformly unrecognizable.

/// Left-half size (matches the stream-cipher key / hash output size).
const LION_L: usize = 32;

/// Four round subkeys derived from a hop's payload key `pi`.
fn lion_subkeys(pi: &[u8; 32]) -> [[u8; 32]; 4] {
    [
        derive(b"aegis/lioness/k1", pi),
        derive(b"aegis/lioness/k2", pi),
        derive(b"aegis/lioness/k3", pi),
        derive(b"aegis/lioness/k4", pi),
    ]
}

/// `data ^= ChaCha20(key)` over `data`'s length (the LIONESS `S`).
fn lion_stream(key: &[u8; 32], data: &mut [u8]) {
    chacha20::xor_stream(key, &NONCE, 0, data);
}

/// `l ^= HMAC(k, r)` (the LIONESS `H`, applied to the 32-byte left half).
fn lion_hash(k: &[u8; 32], r: &[u8], l: &mut [u8]) {
    let h = hmac_sha256(k, r);
    for (b, x) in l.iter_mut().zip(h.iter()) {
        *b ^= x;
    }
}

fn xor32(a: &[u8], k: &[u8; 32]) -> [u8; 32] {
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = a[i] ^ k[i];
    }
    out
}

/// Encrypt one LIONESS layer in place under payload key `pi`.
fn lioness_encrypt(pi: &[u8; 32], block: &mut [u8; PAYLOAD_LEN]) {
    let [k1, k2, k3, k4] = lion_subkeys(pi);
    let (l, r) = block.split_at_mut(LION_L);
    lion_stream(&xor32(l, &k1), r);
    lion_hash(&k2, r, l);
    lion_stream(&xor32(l, &k3), r);
    lion_hash(&k4, r, l);
}

/// Decrypt one LIONESS layer in place under payload key `pi` (rounds reversed).
fn lioness_decrypt(pi: &[u8; 32], block: &mut [u8; PAYLOAD_LEN]) {
    let [k1, k2, k3, k4] = lion_subkeys(pi);
    let (l, r) = block.split_at_mut(LION_L);
    lion_hash(&k4, r, l);
    lion_stream(&xor32(l, &k3), r);
    lion_hash(&k2, r, l);
    lion_stream(&xor32(l, &k1), r);
}

// --- payload padding -----------------------------------------------------
//
// Layout: `len (4 LE) ‖ message ‖ zeros`, fixed to PAYLOAD_LEN, length-hiding
// within the fixed size. The payload is sealed under the LIONESS wide-block
// cipher above, so it is non-malleable: any alteration scrambles the whole
// block, defeating tagging attacks. End-to-end message integrity is still
// additionally provided by the AEAD of the inner (session/mailbox) ciphertext.

fn pad(message: &[u8]) -> Result<[u8; PAYLOAD_LEN], SphinxError> {
    if message.len() + 4 > PAYLOAD_LEN {
        return Err(SphinxError::MessageTooLong);
    }
    let mut out = [0u8; PAYLOAD_LEN];
    out[..4].copy_from_slice(&(message.len() as u32).to_le_bytes());
    out[4..4 + message.len()].copy_from_slice(message);
    Ok(out)
}

fn unpad(padded: &[u8; PAYLOAD_LEN]) -> Result<Vec<u8>, SphinxError> {
    let len = u32::from_le_bytes(padded[..4].try_into().unwrap()) as usize;
    if len + 4 > PAYLOAD_LEN {
        return Err(SphinxError::BadPadding);
    }
    Ok(padded[4..4 + len].to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mixes(n: usize) -> Vec<MixNode> {
        (0..n)
            .map(|i| MixNode::from_seed(&[(i as u8).wrapping_add(1); 32]))
            .collect()
    }

    /// Route a packet through the whole path, returning the delivered payload.
    fn route(mixes: &[MixNode], mut pkt: SphinxPacket) -> Vec<u8> {
        for (i, mix) in mixes.iter().enumerate() {
            match mix.process(&pkt).unwrap() {
                ProcessedPacket::Forward { next, packet } => {
                    assert!(i + 1 < mixes.len(), "forwarded at the exit");
                    assert_eq!(next, mixes[i + 1].id, "wrong next hop");
                    pkt = *packet;
                }
                ProcessedPacket::Deliver { payload } => {
                    assert_eq!(i, mixes.len() - 1, "delivered before the exit");
                    return payload;
                }
            }
        }
        panic!("path ended without delivery");
    }

    #[test]
    fn three_hop_round_trip() {
        let mixes = mixes(3);
        let path: Vec<_> = mixes.iter().map(|m| m.public_hop()).collect();
        let packet = SphinxPacket::seal(&path, b"meet at dawn").unwrap();
        assert_eq!(route(&mixes, packet), b"meet at dawn");
    }

    #[test]
    fn every_path_length_round_trips() {
        for n in 1..=MAX_HOPS {
            let mixes = mixes(n);
            let path: Vec<_> = mixes.iter().map(|m| m.public_hop()).collect();
            let msg = vec![n as u8; 100];
            let packet = SphinxPacket::seal(&path, &msg).unwrap();
            assert_eq!(route(&mixes, packet), msg, "path length {n}");
        }
    }

    #[test]
    fn packet_survives_wire_serialization_between_hops() {
        // A mix forwards by serializing to bytes and the next hop parses them;
        // the routed message must still arrive.
        let mixes = mixes(3);
        let path: Vec<_> = mixes.iter().map(|m| m.public_hop()).collect();
        let mut pkt = SphinxPacket::seal(&path, b"through the wire").unwrap();
        let mut delivered = None;
        for mix in &mixes {
            // Round-trip through the wire form before this hop processes it.
            let bytes = pkt.to_bytes();
            assert_eq!(bytes.len(), PACKET_LEN);
            pkt = SphinxPacket::from_bytes(&bytes).unwrap();
            match mix.process(&pkt).unwrap() {
                ProcessedPacket::Forward { packet, .. } => pkt = *packet,
                ProcessedPacket::Deliver { payload } => {
                    delivered = Some(payload);
                    break;
                }
            }
        }
        assert_eq!(delivered.as_deref(), Some(&b"through the wire"[..]));
    }

    #[test]
    fn from_bytes_rejects_wrong_length() {
        assert!(SphinxPacket::from_bytes(&[0u8; 10]).is_none());
        assert!(SphinxPacket::from_bytes(&[0u8; PACKET_LEN + 1]).is_none());
    }

    #[test]
    fn an_aegis_sized_envelope_fits_one_packet() {
        // A PQXDH handshake envelope is ~3.7 KB; it must ride a single packet.
        let mixes = mixes(2);
        let path: Vec<_> = mixes.iter().map(|m| m.public_hop()).collect();
        let envelope = vec![7u8; 3800];
        let packet = SphinxPacket::seal(&path, &envelope).unwrap();
        assert_eq!(route(&mixes, packet), envelope);
    }

    #[test]
    fn packet_is_fixed_size_at_every_hop() {
        let mixes = mixes(4);
        let path: Vec<_> = mixes.iter().map(|m| m.public_hop()).collect();
        let mut pkt = SphinxPacket::seal(&path, b"x").unwrap();
        for mix in &mixes {
            assert_eq!(pkt.beta.len(), BETA_LEN);
            assert_eq!(pkt.delta.len(), PAYLOAD_LEN);
            match mix.process(&pkt).unwrap() {
                ProcessedPacket::Forward { packet, .. } => pkt = *packet,
                ProcessedPacket::Deliver { .. } => break,
            }
        }
    }

    #[test]
    fn a_wrong_mix_cannot_process() {
        // A mix not on the path fails the MAC check on the first packet.
        let mixes = mixes(3);
        let path: Vec<_> = mixes.iter().map(|m| m.public_hop()).collect();
        let packet = SphinxPacket::seal(&path, b"secret").unwrap();
        let outsider = MixNode::from_seed(&[0xaa; 32]);
        assert!(matches!(
            outsider.process(&packet),
            Err(SphinxError::BadMac)
        ));
    }

    #[test]
    fn payload_tampering_scrambles_delivery_defeating_tagging() {
        // A stream-cipher payload would let an attacker flip a byte at entry and
        // recognize the same flip at the exit (a tagging attack). LIONESS makes
        // the delivered block uniformly unrecognizable instead: the exit either
        // fails to unpad, or recovers bytes unrelated to the original.
        let mixes = mixes(3);
        let path: Vec<_> = mixes.iter().map(|m| m.public_hop()).collect();
        let original = b"secret message to tag";
        let mut packet = SphinxPacket::seal(&path, original).unwrap();
        packet.delta[100] ^= 0xff; // the "tag"

        let mut pkt = packet;
        let mut outcome: Option<Result<Vec<u8>, SphinxError>> = None;
        for mix in &mixes {
            match mix.process(&pkt) {
                Ok(ProcessedPacket::Forward { packet, .. }) => pkt = *packet,
                Ok(ProcessedPacket::Deliver { payload }) => {
                    outcome = Some(Ok(payload));
                    break;
                }
                Err(e) => {
                    outcome = Some(Err(e));
                    break;
                }
            }
        }
        match outcome.expect("packet routed to an end") {
            // Unpadding failed — the tag destroyed the length header. Fine.
            Err(_) => {}
            // Or it "delivered" something, but it must NOT be the tagged original.
            Ok(payload) => assert_ne!(payload.as_slice(), &original[..]),
        }
    }

    #[test]
    fn tampering_the_header_is_detected() {
        let mixes = mixes(3);
        let path: Vec<_> = mixes.iter().map(|m| m.public_hop()).collect();
        let mut packet = SphinxPacket::seal(&path, b"secret").unwrap();
        packet.beta[0] ^= 1;
        assert!(matches!(
            mixes[0].process(&packet),
            Err(SphinxError::BadMac)
        ));
    }

    #[test]
    fn empty_and_overlong_paths_are_rejected() {
        assert!(matches!(
            SphinxPacket::seal(&[], b"x"),
            Err(SphinxError::BadPathLength)
        ));
        let mixes = mixes(MAX_HOPS + 1);
        let path: Vec<_> = mixes.iter().map(|m| m.public_hop()).collect();
        assert!(matches!(
            SphinxPacket::seal(&path, b"x"),
            Err(SphinxError::BadPathLength)
        ));
    }

    #[test]
    fn overlong_message_is_rejected() {
        let mixes = mixes(2);
        let path: Vec<_> = mixes.iter().map(|m| m.public_hop()).collect();
        let big = vec![0u8; PAYLOAD_LEN];
        assert!(matches!(
            SphinxPacket::seal(&path, &big),
            Err(SphinxError::MessageTooLong)
        ));
    }
}
