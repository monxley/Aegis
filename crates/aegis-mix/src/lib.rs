//! # aegis-mix — the Aegis mixnet
//!
//! Turns [`aegis_net`]'s Sphinx routing into a real networked layer, adds a
//! self-organizing **node directory** so clients that are not nodes can find the
//! network, and plugs onion routing into the send path.
//!
//! - [`MixService`] is a **mix node**: it peels one Sphinx layer and forwards to
//!   the next hop or, at the exit, hands the recovered envelope to a [`Deliver`]
//!   sink (its mailbox). It also serves and gossips the [directory](NodeDescriptor)
//!   so the node set propagates without any central server.
//! - [`discover`] lets a plain client bootstrap: ask any reachable node for the
//!   directory and get the whole node set back — **download and use, run
//!   nothing**.
//! - [`MixnetStore`] is a [`MailboxStore`] whose `put` onion-routes an envelope
//!   through a random path of mixes to a provider, so no single node links the
//!   sender to the deposited message. Drop-in: an `AegisClient`/`AegisApp` uses
//!   it unchanged.
//!
//! Wire protocol: one message per TCP connection, a type byte then its body —
//! `FORWARD` (a Sphinx packet), `GET_DIRECTORY` (→ the node set), `ANNOUNCE`
//! (gossip a node set to merge). Sphinx packets are all [`PACKET_LEN`] bytes, so
//! a forwarded packet's size never leaks its position on the path.

use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream, ToSocketAddrs};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use aegis_crypto::fill_random;
use aegis_mailbox::{Envelope, MailboxError, MailboxStore};
use aegis_net::loopix::exp_delay;
use aegis_net::rng::ChaChaRng;
use aegis_net::{
    Hop, MixNode, ProcessedPacket, SphinxPacket, Surb, SurbHeader, NODE_ID_LEN, PACKET_LEN,
    SURB_HEADER_LEN,
};

/// Wire message types (first byte of every connection).
const MSG_FORWARD: u8 = 0x01;
const MSG_GET_DIRECTORY: u8 = 0x02;
const MSG_ANNOUNCE: u8 = 0x03;

/// Proof-of-work difficulty (leading zero bits) a node must burn to join the
/// directory. This makes a **Sybil attack cost CPU per node** — spinning up
/// thousands of fake nodes to dominate path selection is no longer free — without
/// any money, staking, or central admission. Production burns ~2^20 hashes
/// (sub-second on any CPU, once per node); tunable via [`set_pow_difficulty`].
static POW_BITS: std::sync::atomic::AtomicU32 =
    std::sync::atomic::AtomicU32::new(if cfg!(test) { 10 } else { 20 });

/// Set the network's node-admission proof-of-work difficulty (leading zero
/// bits). Operators of a private network can raise it; tests lower it for speed.
/// All nodes must agree on it, since it is the bar a directory verifies against.
pub fn set_pow_difficulty(bits: u32) {
    POW_BITS.store(bits, std::sync::atomic::Ordering::Relaxed);
}

fn pow_bits() -> u32 {
    POW_BITS.load(std::sync::atomic::Ordering::Relaxed)
}

const POW_DOMAIN: &[u8] = b"aegis/node/pow/v1";

fn pow_hash(public: &[u8; 32], nonce: u64) -> [u8; 32] {
    let mut input = Vec::with_capacity(POW_DOMAIN.len() + 40);
    input.extend_from_slice(POW_DOMAIN);
    input.extend_from_slice(public);
    input.extend_from_slice(&nonce.to_le_bytes());
    aegis_crypto::sha256(&input)
}

fn leading_zero_bits(h: &[u8; 32]) -> u32 {
    let mut n = 0;
    for &b in h {
        if b == 0 {
            n += 8;
        } else {
            n += b.leading_zeros();
            break;
        }
    }
    n
}

/// Search for a nonce whose `pow_hash(public, nonce)` has at least `bits` leading
/// zero bits. This is the work a node does once at startup to be admitted.
pub fn mine_pow(public: &[u8; 32], bits: u32) -> u64 {
    let mut nonce = 0u64;
    loop {
        if leading_zero_bits(&pow_hash(public, nonce)) >= bits {
            return nonce;
        }
        nonce = nonce.wrapping_add(1);
    }
}

/// The public description of a mixnet node: its Sphinx id + key, the address to
/// forward Sphinx packets to, an optional blind-mailbox (provider) address, and
/// a **proof-of-work nonce** binding real CPU to this exact key. Descriptors are
/// public and self-authenticating: the id is `SHA-256(public)[..16]`, a wrong
/// key fails routing, and a directory rejects any descriptor whose PoW does not
/// verify (see [`pow_valid`](Self::pow_valid)).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NodeDescriptor {
    pub id: [u8; NODE_ID_LEN],
    pub public: [u8; 32],
    pub mix_addr: SocketAddr,
    /// `Some` if this node is also a provider (a blind mailbox clients poll).
    pub provider_addr: Option<SocketAddr>,
    /// Proof-of-work nonce over `public` at the network difficulty.
    pub pow_nonce: u64,
}

impl NodeDescriptor {
    /// Build a descriptor for **your own** node from its public hop, mix address,
    /// and optional provider address, **mining** the admission proof-of-work
    /// (done once at startup).
    pub fn new(hop: Hop, mix_addr: SocketAddr, provider_addr: Option<SocketAddr>) -> Self {
        let pow_nonce = mine_pow(&hop.public, pow_bits());
        NodeDescriptor {
            id: hop.id,
            public: hop.public,
            mix_addr,
            provider_addr,
            pow_nonce,
        }
    }
    fn hop(&self) -> Hop {
        Hop {
            id: self.id,
            public: self.public,
        }
    }
    /// Whether this node is a provider (runs a mailbox clients can poll).
    pub fn is_provider(&self) -> bool {
        self.provider_addr.is_some()
    }
    /// Verify the id binds to the key and the admission proof-of-work holds.
    /// Directories and clients drop descriptors that fail this.
    pub fn pow_valid(&self) -> bool {
        let id_ok = aegis_crypto::sha256(&self.public)[..NODE_ID_LEN] == self.id;
        id_ok && leading_zero_bits(&pow_hash(&self.public, self.pow_nonce)) >= pow_bits()
    }
}

// --- directory (node set) serialization ----------------------------------

fn put_str(out: &mut Vec<u8>, s: &str) {
    out.extend_from_slice(&(s.len() as u32).to_le_bytes());
    out.extend_from_slice(s.as_bytes());
}

fn encode_directory(nodes: &[NodeDescriptor]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(nodes.len() as u32).to_le_bytes());
    for n in nodes {
        out.extend_from_slice(&n.id);
        out.extend_from_slice(&n.public);
        put_str(&mut out, &n.mix_addr.to_string());
        match &n.provider_addr {
            Some(a) => {
                out.push(1);
                put_str(&mut out, &a.to_string());
            }
            None => out.push(0),
        }
        out.extend_from_slice(&n.pow_nonce.to_le_bytes());
    }
    out
}

fn decode_directory(bytes: &[u8]) -> Option<Vec<NodeDescriptor>> {
    let mut r = Reader::new(bytes);
    let count = r.u32()? as usize;
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        let id = r.take(NODE_ID_LEN)?.try_into().ok()?;
        let public = r.take(32)?.try_into().ok()?;
        let mix_addr = r.string()?.parse().ok()?;
        let provider_addr = match r.u8()? {
            0 => None,
            1 => Some(r.string()?.parse().ok()?),
            _ => return None,
        };
        let pow_nonce = u64::from_le_bytes(r.take(8)?.try_into().ok()?);
        out.push(NodeDescriptor {
            id,
            public,
            mix_addr,
            provider_addr,
            pow_nonce,
        });
    }
    Some(out)
}

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
    fn string(&mut self) -> Option<String> {
        let n = self.u32()? as usize;
        String::from_utf8(self.take(n)?.to_vec()).ok()
    }
}

// --- client-side network calls -------------------------------------------

/// How long a client waits on a single node before giving up: the TCP connect,
/// and each blocking read. Without a bound, an unreachable or silent node (a
/// firewalled port, a half-open connection) hangs the caller forever — on the
/// bootstrap path that shows up as an app frozen on "connecting".
const NET_TIMEOUT: Duration = Duration::from_secs(10);

/// Connect to the first resolvable address with a bounded connect timeout, then
/// arm read/write deadlines so no later blocking read can hang indefinitely.
fn connect_bounded(addr: impl ToSocketAddrs) -> io::Result<TcpStream> {
    let addrs = addr.to_socket_addrs()?;
    let mut last_err =
        io::Error::new(io::ErrorKind::InvalidInput, "no address to connect to");
    for a in addrs {
        match TcpStream::connect_timeout(&a, NET_TIMEOUT) {
            Ok(stream) => {
                stream.set_read_timeout(Some(NET_TIMEOUT))?;
                stream.set_write_timeout(Some(NET_TIMEOUT))?;
                return Ok(stream);
            }
            Err(e) => last_err = e,
        }
    }
    Err(last_err)
}

/// Forward one Sphinx packet to a hop: connect, write `FORWARD ‖ packet`, close.
pub fn dispatch(addr: impl ToSocketAddrs, packet: &SphinxPacket) -> io::Result<()> {
    let mut stream = connect_bounded(addr)?;
    stream.write_all(&[MSG_FORWARD])?;
    stream.write_all(&packet.to_bytes())?;
    stream.flush()
}

/// Ask a node for the current directory (the whole known node set). This is how
/// a client that runs no node bootstraps onto the network.
pub fn discover(seed: impl ToSocketAddrs) -> io::Result<Vec<NodeDescriptor>> {
    let mut stream = connect_bounded(seed)?;
    stream.write_all(&[MSG_GET_DIRECTORY])?;
    stream.flush()?;
    let mut len = [0u8; 4];
    stream.read_exact(&mut len)?;
    let mut body = vec![0u8; u32::from_le_bytes(len) as usize];
    stream.read_exact(&mut body)?;
    let mut nodes =
        decode_directory(&body).ok_or_else(|| io::Error::other("malformed directory"))?;
    // A malicious node might serve unmined descriptors; keep only valid ones.
    nodes.retain(NodeDescriptor::pow_valid);
    Ok(nodes)
}

/// Gossip a node set to a peer for it to merge into its directory.
pub fn announce(peer: impl ToSocketAddrs, nodes: &[NodeDescriptor]) -> io::Result<()> {
    let body = encode_directory(nodes);
    let mut stream = connect_bounded(peer)?;
    stream.write_all(&[MSG_ANNOUNCE])?;
    stream.write_all(&(body.len() as u32).to_le_bytes())?;
    stream.write_all(&body)?;
    stream.flush()
}

// --- delivery sink -------------------------------------------------------

/// A delivered payload's kind (first byte), so a provider exit can tell a stored
/// message from an anonymous fetch request.
const KIND_STORE: u8 = 0x00;
const KIND_FETCH: u8 = 0x01;

/// What a node does at a delivery exit. A provider stores envelopes and answers
/// anonymous fetches; a recipient recovers SURB replies.
pub trait Deliver: Send + Sync {
    /// Store a delivered envelope (a normal send). `payload` is the envelope
    /// bytes, kind byte already stripped.
    fn deliver(&self, payload: Vec<u8>);

    /// Handle a **SURB reply** that arrived at this node (still onion-wrapped).
    /// A node that issues SURBs (to receive its own mail anonymously) overrides
    /// this to match the reply to an outstanding SURB and recover it; the default
    /// drops it.
    fn deliver_reply(&self, _payload: Vec<u8>) {}

    /// Provider read for an anonymous fetch: `(new_cursor, envelopes)` for
    /// everything stored since `cursor`. The default returns `None` (not a
    /// provider — cannot answer fetches).
    fn fetch(&self, _cursor: usize) -> Option<(usize, Vec<Envelope>)> {
        None
    }
}

/// A [`Deliver`] that drops payloads — a pure **forwarder** mix that carries
/// others' traffic but runs no mailbox. This is the light, opt-in role a
/// desktop/Linux client can take on to strengthen the network.
pub struct NullDeliver;

impl Deliver for NullDeliver {
    fn deliver(&self, _payload: Vec<u8>) {}
}

/// A [`Deliver`] that decodes the payload as an [`Envelope`] and puts it in a
/// mailbox store (the node's blind provider). Also answers anonymous fetches by
/// reading that same store.
pub struct MailboxDeliver<S: MailboxStore + Send>(pub Arc<Mutex<S>>);

impl<S: MailboxStore + Send> Deliver for MailboxDeliver<S> {
    fn deliver(&self, payload: Vec<u8>) {
        if let Some(envelope) = Envelope::from_bytes(&payload) {
            if let Ok(mut store) = self.0.lock() {
                let _ = store.put(envelope);
            }
        }
    }
    fn fetch(&self, cursor: usize) -> Option<(usize, Vec<Envelope>)> {
        self.0.lock().ok()?.fetch_since(cursor).ok()
    }
}

// --- the mix node --------------------------------------------------------

/// The shared, mergeable node set a [`MixService`] serves, gossips, and consults
/// for forwarding.
#[derive(Clone, Default)]
pub struct DirectoryState {
    nodes: Arc<Mutex<HashMap<[u8; NODE_ID_LEN], NodeDescriptor>>>,
}

impl DirectoryState {
    pub fn new() -> Self {
        DirectoryState::default()
    }
    /// Seed with a set of known nodes.
    pub fn with_nodes(nodes: &[NodeDescriptor]) -> Self {
        let s = DirectoryState::new();
        s.merge(nodes);
        s
    }
    /// Merge descriptors, keyed by id (last writer wins per id). Descriptors that
    /// fail the admission proof-of-work are **dropped**, so a Sybil flood of
    /// unmined nodes cannot pollute the directory.
    pub fn merge(&self, nodes: &[NodeDescriptor]) {
        let mut map = self.nodes.lock().unwrap();
        for n in nodes {
            if n.pow_valid() {
                map.insert(n.id, n.clone());
            }
        }
    }
    /// A snapshot of the current node set.
    pub fn snapshot(&self) -> Vec<NodeDescriptor> {
        self.nodes.lock().unwrap().values().cloned().collect()
    }
    fn addr(&self, id: &[u8; NODE_ID_LEN]) -> Option<SocketAddr> {
        self.nodes.lock().unwrap().get(id).map(|n| n.mix_addr)
    }
}

/// A networked Sphinx mix node that also serves and gossips the directory.
pub struct MixService<D: Deliver> {
    node: MixNode,
    directory: DirectoryState,
    deliver: D,
    delay_rate: Option<f64>,
}

impl<D: Deliver + 'static> MixService<D> {
    pub fn new(node: MixNode, directory: DirectoryState, deliver: D) -> Self {
        MixService {
            node,
            directory,
            deliver,
            delay_rate: None,
        }
    }

    /// Add a Loopix mixing delay: each forwarded packet waits an independent
    /// `Exp(rate)` time (mean `1/rate` seconds) before going on, so a packet's
    /// arrival and departure are decorrelated (§6.2). Deliveries are not delayed.
    pub fn with_delay(mut self, rate: f64) -> Self {
        self.delay_rate = Some(rate);
        self
    }

    /// The shared directory (to seed, snapshot, or gossip from elsewhere).
    pub fn directory(&self) -> DirectoryState {
        self.directory.clone()
    }

    /// Serve forever: accept connections and handle one message each. Blocks; run
    /// on its own thread.
    pub fn serve(self, listener: TcpListener) -> io::Result<()> {
        let me = Arc::new(self);
        for stream in listener.incoming() {
            let stream = stream?;
            let me = Arc::clone(&me);
            thread::spawn(move || {
                let _ = me.handle(stream);
            });
        }
        Ok(())
    }

    fn handle(&self, mut stream: TcpStream) -> io::Result<()> {
        let mut kind = [0u8; 1];
        stream.read_exact(&mut kind)?;
        match kind[0] {
            MSG_FORWARD => {
                let mut buf = [0u8; PACKET_LEN];
                stream.read_exact(&mut buf)?;
                if let Some(packet) = SphinxPacket::from_bytes(&buf) {
                    self.route(&packet);
                }
            }
            MSG_GET_DIRECTORY => {
                let body = encode_directory(&self.directory.snapshot());
                stream.write_all(&(body.len() as u32).to_le_bytes())?;
                stream.write_all(&body)?;
                stream.flush()?;
            }
            MSG_ANNOUNCE => {
                let mut len = [0u8; 4];
                stream.read_exact(&mut len)?;
                let mut body = vec![0u8; u32::from_le_bytes(len) as usize];
                stream.read_exact(&mut body)?;
                if let Some(nodes) = decode_directory(&body) {
                    self.directory.merge(&nodes);
                }
            }
            _ => {} // unknown — drop
        }
        Ok(())
    }

    fn route(&self, packet: &SphinxPacket) {
        match self.node.process(packet) {
            Ok(ProcessedPacket::Forward { next, packet }) => {
                if let Some(rate) = self.delay_rate {
                    let mut rng = ChaChaRng::from_os();
                    let secs = exp_delay(rate, &mut rng);
                    thread::sleep(Duration::from_secs_f64(secs));
                }
                if let Some(addr) = self.directory.addr(&next) {
                    let _ = dispatch(addr, &packet); // best-effort
                }
            }
            Ok(ProcessedPacket::Deliver { payload }) => self.handle_delivery(payload),
            Ok(ProcessedPacket::DeliverReply { payload }) => self.deliver.deliver_reply(payload),
            Err(_) => {} // bad MAC / degenerate — drop
        }
    }

    /// A payload reached this node as the exit. Its first byte says whether it is
    /// an envelope to store or an anonymous fetch request to answer.
    fn handle_delivery(&self, payload: Vec<u8>) {
        let Some((&kind, body)) = payload.split_first() else {
            return;
        };
        match kind {
            KIND_STORE => self.deliver.deliver(body.to_vec()),
            KIND_FETCH => self.handle_fetch(body),
            _ => {}
        }
    }

    /// Answer an anonymous fetch: read this provider's mailbox from the requested
    /// cursor and send each envelope back through one of the supplied SURBs, so
    /// the reply reaches the recipient without us learning who they are.
    fn handle_fetch(&self, body: &[u8]) {
        let mut r = FetchReader::new(body);
        let Some((cursor, headers)) = r.parse() else {
            return;
        };
        let Some((_new_cursor, envelopes)) = self.deliver.fetch(cursor) else {
            return;
        };
        for (i, env) in envelopes.iter().enumerate().take(headers.len()) {
            // Reply payload: the cursor *after* this envelope ‖ the envelope, so
            // the recipient can advance and re-fetch if more remain.
            let mut reply = ((cursor + i + 1) as u64).to_le_bytes().to_vec();
            reply.extend_from_slice(&env.to_bytes());
            if let Ok(packet) = headers[i].wrap(&reply) {
                if let Some(addr) = self.directory.addr(&headers[i].first_hop) {
                    let _ = dispatch(addr, &packet);
                }
            }
        }
    }
}

/// Run an **opt-in forwarder node**: bind `listen`, learn the network from
/// `bootstrap`, announce itself, serve + gossip, and forward others' traffic. It
/// runs no mailbox (a light role for a desktop/Linux client), optionally with a
/// Loopix `delay_rate`. Returns its descriptor (announce it so others route
/// through you). Spawns background threads and returns immediately.
pub fn spawn_forwarder(
    seed: [u8; 32],
    listen: impl ToSocketAddrs,
    bootstrap: &[SocketAddr],
    delay_rate: Option<f64>,
) -> io::Result<NodeDescriptor> {
    let node = MixNode::from_seed(&seed);
    let listener = TcpListener::bind(listen)?;
    let addr = listener.local_addr()?;
    let desc = NodeDescriptor::new(node.public_hop(), addr, None);

    let dir = DirectoryState::new();
    for b in bootstrap {
        if let Ok(nodes) = discover(b) {
            dir.merge(&nodes);
        }
    }
    dir.merge(std::slice::from_ref(&desc));

    let mut service = MixService::new(node, dir.clone(), NullDeliver);
    if let Some(rate) = delay_rate {
        service = service.with_delay(rate);
    }
    thread::spawn(move || {
        let _ = service.serve(listener);
    });
    run_gossip(dir, desc.clone(), Duration::from_secs(30));
    Ok(desc)
}

/// Run a **receiver node**: like [`spawn_forwarder`], but its delivery sink is a
/// [`SurbInbox`] so it can receive its own mail anonymously (SURB replies land
/// here). It announces itself to every known node immediately, so mixes can route
/// replies back to it without waiting for a gossip round. `advertise` is the
/// public address others reach it at (default: the bound address).
pub fn spawn_receiver(
    seed: [u8; 32],
    listen: impl ToSocketAddrs,
    bootstrap: &[SocketAddr],
    inbox: SurbInbox,
    advertise: Option<SocketAddr>,
) -> io::Result<NodeDescriptor> {
    let node = MixNode::from_seed(&seed);
    let listener = TcpListener::bind(listen)?;
    let addr = match advertise {
        Some(a) => a,
        None => listener.local_addr()?,
    };
    let desc = NodeDescriptor::new(node.public_hop(), addr, None);

    let dir = DirectoryState::new();
    for b in bootstrap {
        if let Ok(nodes) = discover(b) {
            dir.merge(&nodes);
        }
    }
    dir.merge(std::slice::from_ref(&desc));
    // Announce ourselves now so others can route SURB replies to us.
    for peer in dir.snapshot() {
        if peer.id != desc.id {
            let _ = announce(peer.mix_addr, std::slice::from_ref(&desc));
        }
    }

    let service = MixService::new(node, dir.clone(), inbox);
    thread::spawn(move || {
        let _ = service.serve(listener);
    });
    run_gossip(dir, desc.clone(), Duration::from_secs(30));
    Ok(desc)
}

/// Send one **cover packet** into the mixnet: a decoy routed through a random
/// path of mixes whose exit discards it, indistinguishable on the wire from a
/// real send. Call it on a Poisson schedule so a network observer cannot tell
/// when you are actually sending (§6.2). Best-effort.
pub fn send_cover(pool: &[NodeDescriptor], hops: usize) -> io::Result<()> {
    if pool.is_empty() {
        return Ok(());
    }
    let hop_descs: Vec<Hop> = pool.iter().map(NodeDescriptor::hop).collect();
    let mut rng = ChaChaRng::from_os();
    let hops = hops.clamp(1, aegis_net::MAX_HOPS);
    let packet = aegis_net::loopix::drop_cover(&hop_descs, hops, &mut rng)
        .map_err(|e| io::Error::other(format!("cover: {e}")))?;
    // Send to a random entry among the pool.
    let entry = &pool[(random_u64() as usize) % pool.len()];
    dispatch(entry.mix_addr, &packet)
}

// --- anonymous receive (SURB poll-through-mixnet) ------------------------

/// The most SURB headers that fit one fetch request's fixed payload.
pub const MAX_FETCH_SURBS: usize = (aegis_net::PAYLOAD_LEN - 1 - 8 - 4) / SURB_HEADER_LEN;

/// Reads a fetch request body: `cursor(8) ‖ count(4) ‖ [SurbHeader…]`.
struct FetchReader<'a> {
    buf: &'a [u8],
    pos: usize,
}
impl<'a> FetchReader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        FetchReader { buf, pos: 0 }
    }
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let end = self.pos.checked_add(n)?;
        let s = self.buf.get(self.pos..end)?;
        self.pos = end;
        Some(s)
    }
    fn parse(&mut self) -> Option<(usize, Vec<SurbHeader>)> {
        let cursor = u64::from_le_bytes(self.take(8)?.try_into().ok()?) as usize;
        let count = u32::from_le_bytes(self.take(4)?.try_into().ok()?) as usize;
        let mut headers = Vec::with_capacity(count);
        for _ in 0..count {
            headers.push(SurbHeader::from_bytes(self.take(SURB_HEADER_LEN)?)?);
        }
        Some((cursor, headers))
    }
}

/// Ask a provider — reached by onion-routing through `path` (whose exit is the
/// provider) — to return mail since `cursor`, wrapping each envelope in one of
/// `surbs` and routing it back. The provider **never learns who is asking**: the
/// request arrives via mixes, and the replies leave via the SURBs. Send at most
/// [`MAX_FETCH_SURBS`] headers. Dispatch enters the mixnet at `entry_addr`
/// (`path[0]`'s address).
pub fn anonymous_fetch(
    path: &[Hop],
    entry_addr: impl ToSocketAddrs,
    cursor: usize,
    surbs: &[SurbHeader],
) -> io::Result<()> {
    let mut body = vec![KIND_FETCH];
    body.extend_from_slice(&(cursor as u64).to_le_bytes());
    body.extend_from_slice(&(surbs.len() as u32).to_le_bytes());
    for h in surbs {
        body.extend_from_slice(&h.to_bytes());
    }
    let packet = SphinxPacket::seal(path, &body)
        .map_err(|e| io::Error::other(format!("fetch seal: {e}")))?;
    dispatch(entry_addr, &packet)
}

/// The recipient side of anonymous receive: a [`Deliver`] that holds the SURBs a
/// recipient issued and, as replies arrive, recovers the envelopes they carry.
/// A recipient runs this as its node's delivery sink and issues SURBs routed back
/// to that node. Cloneable and shareable (its state is behind an `Arc`).
#[derive(Clone, Default)]
pub struct SurbInbox {
    inner: Arc<SurbInboxInner>,
}

#[derive(Default)]
struct SurbInboxInner {
    outstanding: Mutex<Vec<Surb>>,
    received: Mutex<Vec<(usize, Envelope)>>,
}

impl SurbInbox {
    pub fn new() -> Self {
        SurbInbox::default()
    }

    /// Register a SURB the recipient built (routed back to its own node), so a
    /// reply carried by it can be recovered when it arrives.
    pub fn issue(&self, surb: Surb) {
        self.inner.outstanding.lock().unwrap().push(surb);
    }

    /// Take everything recovered so far: `(cursor_after, envelope)` pairs. Scan
    /// the envelopes with the recipient's view key; advance the poll cursor to the
    /// largest `cursor_after`.
    pub fn drain(&self) -> Vec<(usize, Envelope)> {
        std::mem::take(&mut *self.inner.received.lock().unwrap())
    }
}

impl Deliver for SurbInbox {
    fn deliver(&self, _payload: Vec<u8>) {} // a recipient is not a provider

    fn deliver_reply(&self, payload: Vec<u8>) {
        let mut outstanding = self.inner.outstanding.lock().unwrap();
        // A single-use SURB matches exactly one reply; try each until one peels.
        for i in 0..outstanding.len() {
            if let Ok(msg) = outstanding[i].recover(&payload) {
                if msg.len() >= 8 {
                    let cursor_after = u64::from_le_bytes(msg[..8].try_into().unwrap()) as usize;
                    if let Some(env) = Envelope::from_bytes(&msg[8..]) {
                        self.inner
                            .received
                            .lock()
                            .unwrap()
                            .push((cursor_after, env));
                    }
                }
                outstanding.remove(i);
                return;
            }
        }
    }
}

/// Periodically gossip `own` and everything known to every peer in `directory`,
/// so the node set converges. Runs until the process exits; spawn it.
pub fn run_gossip(directory: DirectoryState, own: NodeDescriptor, every: Duration) {
    thread::spawn(move || loop {
        directory.merge(std::slice::from_ref(&own));
        let all = directory.snapshot();
        for peer in &all {
            if peer.id != own.id {
                let _ = announce(peer.mix_addr, &all);
            }
        }
        thread::sleep(every);
    });
}

// --- the onion-routing store ---------------------------------------------

/// A [`MailboxStore`] that **sends through the mixnet** and **reads from this
/// user's provider**. Mail is **sharded across providers**: a message for a
/// recipient is onion-routed to the provider that recipient polls, chosen
/// deterministically from the recipient's (public) view key — so senders and the
/// recipient agree on where it lands without any node learning the pairing.
/// `fetch_since` reads only this user's own provider.
///
/// All clients must see the same provider set (sorted by id) for the sharding to
/// agree; the gossiped directory converges on it. Receive-path anonymity (not
/// revealing which provider you poll) is a later increment.
pub struct MixnetStore<P: MailboxStore> {
    reader: P,
    providers: Vec<NodeDescriptor>,
    pool: Vec<NodeDescriptor>,
    own_provider: NodeDescriptor,
    hops: usize,
    anon: Option<AnonReceive>,
}

/// Anonymous-receive state: instead of polling the provider directly,
/// `fetch_since` onion-routes a fetch and harvests SURB replies, so the provider
/// never learns who is polling. Requires this user to run a reachable node
/// (`own_node`) whose delivery sink is `inbox`.
struct AnonReceive {
    inbox: SurbInbox,
    own_node: NodeDescriptor,
    cursor: Mutex<usize>,
}

impl<P: MailboxStore> MixnetStore<P> {
    /// * `reader` — reads this user's mail from `own_provider`'s mailbox.
    /// * `providers` — every provider in the network (sharding targets); sorted
    ///   by id internally so all clients agree.
    /// * `pool` — candidate intermediate hops: **all** nodes work (every node is
    ///   a mix), the exit is just excluded per route.
    /// * `own_provider` — the provider this user polls (its shard).
    /// * `hops` — mixes before the exit, clamped to fit [`aegis_net::MAX_HOPS`].
    pub fn new(
        reader: P,
        mut providers: Vec<NodeDescriptor>,
        pool: Vec<NodeDescriptor>,
        own_provider: NodeDescriptor,
        hops: usize,
    ) -> Self {
        providers.sort_by_key(|p| p.id);
        let hops = hops.min(aegis_net::MAX_HOPS.saturating_sub(1));
        MixnetStore {
            reader,
            providers,
            pool,
            own_provider,
            hops,
            anon: None,
        }
    }

    /// Enable **anonymous receive**: `fetch_since` will onion-route a fetch to
    /// the provider and collect the replies via SURBs routed back to `own_node`,
    /// instead of polling the provider directly. `inbox` must be the delivery
    /// sink of the running [`MixService`] for `own_node`, and `own_node` must be
    /// reachable and in the directory. Falls back to a direct read if there are
    /// no mixes to route through.
    pub fn with_anon_receive(mut self, inbox: SurbInbox, own_node: NodeDescriptor) -> Self {
        self.anon = Some(AnonReceive {
            inbox,
            own_node,
            cursor: Mutex::new(0),
        });
        self
    }

    /// Issue a batch of return SURBs (routed back to our own node) and onion-route
    /// a fetch request to our provider from `cursor`. Replies land in the inbox.
    /// Emit one **cover packet** into the mixnet through this store's node pool
    /// (a decoy the exit discards), so a network observer cannot tell a real send
    /// from silence. Call it on a Poisson schedule. No-op if there are no mixes.
    pub fn send_cover(&self) -> Result<(), MailboxError> {
        crate::send_cover(&self.pool, self.hops.max(1))
            .map_err(|e| MailboxError(format!("cover: {e}")))
    }

    fn issue_anon_fetch(&self, anon: &AnonReceive, cursor: usize) {
        let batch = MAX_FETCH_SURBS.min(4);
        let mut headers = Vec::with_capacity(batch);
        for _ in 0..batch {
            let mut back = choose_excluding(&self.pool, self.hops, &anon.own_node.id);
            back.push(anon.own_node.clone());
            let hops: Vec<Hop> = back.iter().map(NodeDescriptor::hop).collect();
            if let Ok(surb) = Surb::create(&hops) {
                headers.push(surb.header.clone());
                anon.inbox.issue(surb);
            }
        }
        if headers.is_empty() {
            return;
        }
        let mut route = choose_excluding(&self.pool, self.hops, &self.own_provider.id);
        route.push(self.own_provider.clone());
        let hops: Vec<Hop> = route.iter().map(NodeDescriptor::hop).collect();
        let _ = anonymous_fetch(&hops, route[0].mix_addr, cursor, &headers);
    }

    /// The provider a message for `recipient` should land at (its shard).
    fn provider_for(&self, recipient: &aegis_mailbox::RecipientKey) -> NodeDescriptor {
        if self.providers.is_empty() {
            return self.own_provider.clone();
        }
        self.providers[provider_index(&recipient.0, self.providers.len())].clone()
    }

    fn route(&self, exit: &NodeDescriptor, envelope: &Envelope) -> Result<(), MailboxError> {
        let mut route = choose_excluding(&self.pool, self.hops, &exit.id);
        route.push(exit.clone());
        let hops: Vec<Hop> = route.iter().map(NodeDescriptor::hop).collect();
        // KIND_STORE ‖ envelope, so the exit provider stores it (vs. a fetch).
        let mut body = vec![KIND_STORE];
        body.extend_from_slice(&envelope.to_bytes());
        let packet = SphinxPacket::seal(&hops, &body)
            .map_err(|e| MailboxError(format!("sphinx seal: {e}")))?;
        dispatch(route[0].mix_addr, &packet).map_err(|e| MailboxError(format!("dispatch: {e}")))?;
        Ok(())
    }
}

impl<P: MailboxStore> MailboxStore for MixnetStore<P> {
    fn put(&mut self, envelope: Envelope) -> Result<(), MailboxError> {
        // No recipient hint — route to our own provider (correct for a reply the
        // caller already addressed; `put_for` is the sharded path).
        let exit = self.own_provider.clone();
        self.route(&exit, &envelope)
    }

    fn put_for(
        &mut self,
        recipient: &aegis_mailbox::RecipientKey,
        envelope: Envelope,
    ) -> Result<(), MailboxError> {
        let exit = self.provider_for(recipient);
        self.route(&exit, &envelope)
    }

    fn fetch_since(&self, cursor: usize) -> Result<(usize, Vec<Envelope>), MailboxError> {
        let Some(anon) = &self.anon else {
            return self.reader.fetch_since(cursor);
        };
        // Anonymous receive: harvest replies from the previous fetch, advance the
        // cursor by what came back, then issue the next fetch. Each poll both
        // collects and re-asks, so mail streams in over successive polls without
        // the provider ever seeing who we are.
        let mut cur = anon.cursor.lock().unwrap();
        let mut envelopes = Vec::new();
        for (cursor_after, env) in anon.inbox.drain() {
            *cur = (*cur).max(cursor_after);
            envelopes.push(env);
        }
        self.issue_anon_fetch(anon, *cur);
        Ok((*cur, envelopes))
    }
}

/// The index into a **sorted-by-id** provider list that a recipient's view key
/// shards to. Deterministic, so every sender and the recipient pick the same
/// provider. Returns 0 if there are no providers.
pub fn provider_index(view_public: &[u8; 32], num_providers: usize) -> usize {
    if num_providers == 0 {
        return 0;
    }
    let h = aegis_crypto::sha256(view_public);
    (u64::from_le_bytes(h[..8].try_into().unwrap()) as usize) % num_providers
}

/// Pick `k` distinct nodes from `pool` with OS randomness (partial Fisher–Yates).
fn choose(pool: &[NodeDescriptor], k: usize) -> Vec<NodeDescriptor> {
    let mut idx: Vec<usize> = (0..pool.len()).collect();
    let k = k.min(idx.len());
    for i in 0..k {
        let j = i + (random_u64() as usize) % (idx.len() - i);
        idx.swap(i, j);
    }
    idx[..k].iter().map(|&i| pool[i].clone()).collect()
}

/// Like [`choose`] but never picks the node with id `exclude` (the exit), so an
/// intermediate hop is always a *different* node. Every node can forward, so the
/// pool is the whole network, not just non-providers.
fn choose_excluding(
    pool: &[NodeDescriptor],
    k: usize,
    exclude: &[u8; NODE_ID_LEN],
) -> Vec<NodeDescriptor> {
    let candidates: Vec<NodeDescriptor> =
        pool.iter().filter(|n| &n.id != exclude).cloned().collect();
    choose(&candidates, k)
}

fn random_u64() -> u64 {
    let mut b = [0u8; 8];
    fill_random(&mut b);
    u64::from_le_bytes(b)
}

#[cfg(test)]
mod tests {
    use super::*;
    use aegis_mailbox::InMemoryStore;

    struct Collect(Arc<Mutex<Vec<Vec<u8>>>>);
    impl Deliver for Collect {
        fn deliver(&self, payload: Vec<u8>) {
            self.0.lock().unwrap().push(payload);
        }
    }

    /// Spawn a mix node seeded with `known`; return its descriptor.
    fn spawn_mix(
        seed: u8,
        known: &[NodeDescriptor],
        provider: Option<SocketAddr>,
        deliver: impl Deliver + 'static,
    ) -> (NodeDescriptor, DirectoryState) {
        let node = MixNode::from_seed(&[seed; 32]);
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let desc = NodeDescriptor::new(node.public_hop(), addr, provider);
        let dir = DirectoryState::with_nodes(known);
        dir.merge(std::slice::from_ref(&desc));
        let service = MixService::new(node, dir.clone(), deliver);
        thread::spawn(move || {
            let _ = service.serve(listener);
        });
        (desc, dir)
    }

    #[test]
    fn a_packet_routes_through_three_networked_mixes() {
        let got = Arc::new(Mutex::new(Vec::new()));
        let (exit, _) = spawn_mix(3, &[], None, Collect(Arc::clone(&got)));
        let (mid, _) = spawn_mix(2, std::slice::from_ref(&exit), None, Collect(got.clone()));
        let (entry, _) = spawn_mix(1, std::slice::from_ref(&mid), None, Collect(got.clone()));

        let path = [entry.hop(), mid.hop(), exit.hop()];
        // Delivered payloads are kind-tagged; a stored message is KIND_STORE.
        let mut body = vec![KIND_STORE];
        body.extend_from_slice(b"routed hello");
        let packet = SphinxPacket::seal(&path, &body).unwrap();
        dispatch(entry.mix_addr, &packet).unwrap();

        wait_for(&got, 1);
        assert_eq!(got.lock().unwrap()[0], b"routed hello");
    }

    #[test]
    fn a_client_discovers_the_node_set_from_a_seed() {
        // The seed node knows about two others; a plain client asks and learns all.
        let (a, _) = spawn_mix(
            11,
            &[],
            Some("127.0.0.1:6001".parse().unwrap()),
            Collect(nil()),
        );
        let (b, _) = spawn_mix(12, &[], None, Collect(nil()));
        let (seed, _) = spawn_mix(10, &[a.clone(), b.clone()], None, Collect(nil()));

        let mut found = discover(seed.mix_addr).unwrap();
        found.sort_by_key(|n| n.id);
        let mut want = vec![a, b, seed];
        want.sort_by_key(|n| n.id);
        assert_eq!(found, want);
    }

    #[test]
    fn announce_merges_into_a_nodes_directory() {
        let (node, dir) = spawn_mix(20, &[], None, Collect(nil()));
        assert_eq!(dir.snapshot().len(), 1);
        let peer = MixNode::from_seed(&[42u8; 32]);
        let newcomer =
            NodeDescriptor::new(peer.public_hop(), "127.0.0.1:6100".parse().unwrap(), None);
        let newcomer_id = newcomer.id;
        announce(node.mix_addr, std::slice::from_ref(&newcomer)).unwrap();
        // Give the server a moment to merge.
        for _ in 0..100 {
            if dir.snapshot().len() == 2 {
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }
        assert!(dir.snapshot().iter().any(|n| n.id == newcomer_id));
    }

    #[test]
    fn pow_gates_the_directory() {
        // A descriptor with a bad proof-of-work is dropped on merge.
        let dir = DirectoryState::new();
        let node = MixNode::from_seed(&[77u8; 32]);
        let mut bad =
            NodeDescriptor::new(node.public_hop(), "127.0.0.1:6500".parse().unwrap(), None);
        assert!(bad.pow_valid());
        bad.pow_nonce = bad.pow_nonce.wrapping_add(1); // break the proof
        assert!(!bad.pow_valid());
        dir.merge(std::slice::from_ref(&bad));
        assert!(dir.snapshot().is_empty(), "unmined node must be rejected");

        let good = NodeDescriptor::new(node.public_hop(), "127.0.0.1:6500".parse().unwrap(), None);
        dir.merge(std::slice::from_ref(&good));
        assert_eq!(dir.snapshot().len(), 1);
    }

    #[test]
    fn mixnet_store_delivers_via_discovery() {
        // Stand up a provider + a mix, then a client discovers them and sends.
        let mailbox = Arc::new(Mutex::new(InMemoryStore::new()));
        let (exit, _) = spawn_mix(
            31,
            &[],
            Some("127.0.0.1:6200".parse().unwrap()),
            MailboxDeliver(Arc::clone(&mailbox)),
        );
        let (mid, _) = spawn_mix(21, std::slice::from_ref(&exit), None, Collect(nil()));

        // The client discovers the network from the mix (which knows the exit).
        let dir = discover(mid.mix_addr).unwrap();
        let pool: Vec<_> = dir.iter().filter(|n| !n.is_provider()).cloned().collect();
        let exit_desc = dir.iter().find(|n| n.is_provider()).unwrap().clone();

        let reader = SharedRead(Arc::clone(&mailbox));
        let mut store = MixnetStore::new(reader, vec![exit_desc.clone()], pool, exit_desc, 1);
        store
            .put(Envelope::from_bytes(&sample_envelope()).unwrap())
            .unwrap();

        wait_for_mailbox(&mailbox, 1);
        assert_eq!(
            store.fetch_since(0).unwrap().1[0].to_bytes(),
            sample_envelope()
        );
    }

    #[test]
    fn an_optin_forwarder_joins_and_carries_traffic() {
        // A provider is up; a client turns on forwarder mode pointed at it. The
        // forwarder learns the provider, a client discovers the whole net from
        // the forwarder, and a message routes client -> forwarder -> provider.
        let mailbox = Arc::new(Mutex::new(InMemoryStore::new()));
        let (exit, _) = spawn_mix(
            41,
            &[],
            Some("127.0.0.1:6300".parse().unwrap()),
            MailboxDeliver(Arc::clone(&mailbox)),
        );

        let fwd = spawn_forwarder([50u8; 32], "127.0.0.1:0", &[exit.mix_addr], None).unwrap();

        let dir = discover(fwd.mix_addr).unwrap();
        assert!(dir.iter().any(|n| n.id == exit.id));
        let pool: Vec<_> = dir.iter().filter(|n| !n.is_provider()).cloned().collect();

        // Cover traffic through the forwarder is accepted and discarded.
        send_cover(&pool, 1).unwrap();

        let reader = SharedRead(Arc::clone(&mailbox));
        let mut store = MixnetStore::new(reader, vec![exit.clone()], pool, exit, 1);
        store
            .put(Envelope::from_bytes(&sample_envelope()).unwrap())
            .unwrap();
        wait_for_mailbox(&mailbox, 1);
        assert_eq!(
            store.fetch_since(0).unwrap().1[0].to_bytes(),
            sample_envelope()
        );
    }

    #[test]
    fn mail_is_sharded_to_the_recipients_provider() {
        // Two providers with separate mailboxes; put_for a recipient must land on
        // exactly the provider that recipient's view key shards to.
        let mb_a = Arc::new(Mutex::new(InMemoryStore::new()));
        let mb_b = Arc::new(Mutex::new(InMemoryStore::new()));
        let (pa, _) = spawn_mix(
            60,
            &[],
            Some("127.0.0.1:6400".parse().unwrap()),
            MailboxDeliver(Arc::clone(&mb_a)),
        );
        let (pb, _) = spawn_mix(
            61,
            std::slice::from_ref(&pa),
            Some("127.0.0.1:6401".parse().unwrap()),
            MailboxDeliver(Arc::clone(&mb_b)),
        );
        let dir = discover(pb.mix_addr).unwrap();
        let providers: Vec<_> = dir.iter().filter(|n| n.is_provider()).cloned().collect();
        assert_eq!(providers.len(), 2);

        let mut sorted = providers.clone();
        sorted.sort_by_key(|p| p.id);
        let recipient = aegis_mailbox::RecipientKey([9u8; 32]);
        let expected = &sorted[provider_index(&recipient.0, 2)];
        let (expected_mb, other_mb) = if expected.id == pa.id {
            (&mb_a, &mb_b)
        } else {
            (&mb_b, &mb_a)
        };

        let reader = SharedRead(Arc::clone(&mb_a));
        let mut store = MixnetStore::new(reader, providers, vec![], pa.clone(), 0);
        store
            .put_for(
                &recipient,
                Envelope::from_bytes(&sample_envelope()).unwrap(),
            )
            .unwrap();

        wait_for_mailbox(expected_mb, 1);
        assert_eq!(other_mb.lock().unwrap().fetch_since(0).unwrap().1.len(), 0);
    }

    #[test]
    fn anonymous_receive_over_surbs() {
        use aegis_identity::Identity;

        // Three nodes sharing one directory: a forwarder, a provider (mailbox),
        // and the recipient's own node (its SURB exit).
        let mailbox = Arc::new(Mutex::new(InMemoryStore::new()));
        let inbox = SurbInbox::new();

        let fwd_l = TcpListener::bind("127.0.0.1:0").unwrap();
        let prov_l = TcpListener::bind("127.0.0.1:0").unwrap();
        let recip_l = TcpListener::bind("127.0.0.1:0").unwrap();
        let fwd_node = MixNode::from_seed(&[70u8; 32]);
        let prov_node = MixNode::from_seed(&[71u8; 32]);
        let recip_node = MixNode::from_seed(&[72u8; 32]);
        let fwd = NodeDescriptor::new(fwd_node.public_hop(), fwd_l.local_addr().unwrap(), None);
        let prov = NodeDescriptor::new(
            prov_node.public_hop(),
            prov_l.local_addr().unwrap(),
            Some("127.0.0.1:1".parse().unwrap()),
        );
        let recip =
            NodeDescriptor::new(recip_node.public_hop(), recip_l.local_addr().unwrap(), None);

        let dir = DirectoryState::with_nodes(&[fwd.clone(), prov.clone(), recip.clone()]);
        {
            let d = dir.clone();
            thread::spawn(move || {
                let _ = MixService::new(fwd_node, d, NullDeliver).serve(fwd_l);
            });
            let d = dir.clone();
            let mb = MailboxDeliver(Arc::clone(&mailbox));
            thread::spawn(move || {
                let _ = MixService::new(prov_node, d, mb).serve(prov_l);
            });
            let d = dir.clone();
            let ib = inbox.clone();
            thread::spawn(move || {
                let _ = MixService::new(recip_node, d, ib).serve(recip_l);
            });
        }

        // A message was already stored for the recipient in the provider mailbox.
        let bob = Identity::from_secret_bytes([9u8; 32], [8u8; 32], [7u8; 32]);
        let envelope = aegis_mailbox::seal(&bob.view_public(), b"anonymous inbox!").unwrap();
        mailbox.lock().unwrap().put(envelope).unwrap();

        // Bob issues a SURB routed back to his own node (via the forwarder), and
        // asks the provider (onion-routed via the forwarder) to reply through it.
        let return_surb = Surb::create(&[fwd.hop(), recip.hop()]).unwrap();
        let header = return_surb.header.clone();
        inbox.issue(return_surb);

        anonymous_fetch(&[fwd.hop(), prov.hop()], fwd.mix_addr, 0, &[header]).unwrap();

        // The reply comes back through the mixnet into Bob's inbox.
        let mut got = Vec::new();
        for _ in 0..200 {
            got = inbox.drain();
            if !got.is_empty() {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(got.len(), 1, "expected one envelope back over the SURB");
        let (cursor_after, env) = &got[0];
        assert_eq!(*cursor_after, 1);
        // The provider never learned who Bob is; Bob opens it with his view key.
        assert_eq!(
            aegis_mailbox::open(bob.view(), env).as_deref(),
            Some(&b"anonymous inbox!"[..])
        );
    }

    // --- helpers ---

    fn nil() -> Arc<Mutex<Vec<Vec<u8>>>> {
        Arc::new(Mutex::new(Vec::new()))
    }

    struct SharedRead(Arc<Mutex<InMemoryStore>>);
    impl MailboxStore for SharedRead {
        fn put(&mut self, e: Envelope) -> Result<(), MailboxError> {
            self.0.lock().unwrap().put(e)
        }
        fn fetch_since(&self, c: usize) -> Result<(usize, Vec<Envelope>), MailboxError> {
            self.0.lock().unwrap().fetch_since(c)
        }
    }

    fn sample_envelope() -> Vec<u8> {
        let mut v = vec![1u8; 16];
        v.push(7);
        v.extend_from_slice(&[2u8; 32]);
        v.extend_from_slice(b"ciphertext bytes");
        v
    }

    fn wait_for(got: &Arc<Mutex<Vec<Vec<u8>>>>, n: usize) {
        for _ in 0..200 {
            if got.lock().unwrap().len() >= n {
                return;
            }
            thread::sleep(Duration::from_millis(10));
        }
        panic!("timed out waiting for {n} delivery(ies)");
    }

    fn wait_for_mailbox(m: &Arc<Mutex<InMemoryStore>>, n: usize) {
        for _ in 0..200 {
            if m.lock().unwrap().fetch_since(0).unwrap().1.len() >= n {
                return;
            }
            thread::sleep(Duration::from_millis(10));
        }
        panic!("timed out waiting for mailbox");
    }
}
