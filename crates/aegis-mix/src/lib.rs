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
use aegis_net::{Hop, MixNode, ProcessedPacket, SphinxPacket, NODE_ID_LEN, PACKET_LEN};

/// Wire message types (first byte of every connection).
const MSG_FORWARD: u8 = 0x01;
const MSG_GET_DIRECTORY: u8 = 0x02;
const MSG_ANNOUNCE: u8 = 0x03;

/// The public description of a mixnet node: its Sphinx id + key, the address to
/// forward Sphinx packets to, and — if it also runs a blind mailbox — the
/// address clients poll for mail. Descriptors are public and self-authenticating
/// (the id is `SHA-256(public)[..16]`, and a wrong key simply fails routing).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NodeDescriptor {
    pub id: [u8; NODE_ID_LEN],
    pub public: [u8; 32],
    pub mix_addr: SocketAddr,
    /// `Some` if this node is also a provider (a blind mailbox clients poll).
    pub provider_addr: Option<SocketAddr>,
}

impl NodeDescriptor {
    /// Build from a mix node's public hop, its mix address, and an optional
    /// provider (mailbox) address.
    pub fn new(hop: Hop, mix_addr: SocketAddr, provider_addr: Option<SocketAddr>) -> Self {
        NodeDescriptor {
            id: hop.id,
            public: hop.public,
            mix_addr,
            provider_addr,
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
        out.push(NodeDescriptor {
            id,
            public,
            mix_addr,
            provider_addr,
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

/// Forward one Sphinx packet to a hop: connect, write `FORWARD ‖ packet`, close.
pub fn dispatch(addr: impl ToSocketAddrs, packet: &SphinxPacket) -> io::Result<()> {
    let mut stream = TcpStream::connect(addr)?;
    stream.write_all(&[MSG_FORWARD])?;
    stream.write_all(&packet.to_bytes())?;
    stream.flush()
}

/// Ask a node for the current directory (the whole known node set). This is how
/// a client that runs no node bootstraps onto the network.
pub fn discover(seed: impl ToSocketAddrs) -> io::Result<Vec<NodeDescriptor>> {
    let mut stream = TcpStream::connect(seed)?;
    stream.write_all(&[MSG_GET_DIRECTORY])?;
    stream.flush()?;
    let mut len = [0u8; 4];
    stream.read_exact(&mut len)?;
    let mut body = vec![0u8; u32::from_le_bytes(len) as usize];
    stream.read_exact(&mut body)?;
    decode_directory(&body).ok_or_else(|| io::Error::other("malformed directory"))
}

/// Gossip a node set to a peer for it to merge into its directory.
pub fn announce(peer: impl ToSocketAddrs, nodes: &[NodeDescriptor]) -> io::Result<()> {
    let body = encode_directory(nodes);
    let mut stream = TcpStream::connect(peer)?;
    stream.write_all(&[MSG_ANNOUNCE])?;
    stream.write_all(&(body.len() as u32).to_le_bytes())?;
    stream.write_all(&body)?;
    stream.flush()
}

// --- delivery sink -------------------------------------------------------

/// What an exit mix does with a recovered payload — normally: decode the Aegis
/// envelope and store it in the node's mailbox.
pub trait Deliver: Send + Sync {
    fn deliver(&self, payload: Vec<u8>);
}

/// A [`Deliver`] that drops payloads — a pure **forwarder** mix that carries
/// others' traffic but runs no mailbox. This is the light, opt-in role a
/// desktop/Linux client can take on to strengthen the network.
pub struct NullDeliver;

impl Deliver for NullDeliver {
    fn deliver(&self, _payload: Vec<u8>) {}
}

/// A [`Deliver`] that decodes the payload as an [`Envelope`] and puts it in a
/// mailbox store (the node's blind provider).
pub struct MailboxDeliver<S: MailboxStore + Send>(pub Arc<Mutex<S>>);

impl<S: MailboxStore + Send> Deliver for MailboxDeliver<S> {
    fn deliver(&self, payload: Vec<u8>) {
        if let Some(envelope) = Envelope::from_bytes(&payload) {
            if let Ok(mut store) = self.0.lock() {
                let _ = store.put(envelope);
            }
        }
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
    /// Merge descriptors, keyed by id (last writer wins per id).
    pub fn merge(&self, nodes: &[NodeDescriptor]) {
        let mut map = self.nodes.lock().unwrap();
        for n in nodes {
            map.insert(n.id, n.clone());
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
            Ok(ProcessedPacket::Deliver { payload }) => self.deliver.deliver(payload),
            Err(_) => {} // bad MAC / degenerate — drop
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
}

impl<P: MailboxStore> MixnetStore<P> {
    /// * `reader` — reads this user's mail from `own_provider`'s mailbox.
    /// * `providers` — every provider in the network (sharding targets); sorted
    ///   by id internally so all clients agree.
    /// * `pool` — candidate intermediate mixes to route through.
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
        let max_mid = aegis_net::MAX_HOPS.saturating_sub(1);
        let hops = hops.min(max_mid).min(pool.len());
        MixnetStore {
            reader,
            providers,
            pool,
            own_provider,
            hops,
        }
    }

    /// The provider a message for `recipient` should land at (its shard).
    fn provider_for(&self, recipient: &aegis_mailbox::RecipientKey) -> NodeDescriptor {
        if self.providers.is_empty() {
            return self.own_provider.clone();
        }
        self.providers[provider_index(&recipient.0, self.providers.len())].clone()
    }

    fn route(&self, exit: &NodeDescriptor, envelope: &Envelope) -> Result<(), MailboxError> {
        let mut route = choose(&self.pool, self.hops);
        route.push(exit.clone());
        let hops: Vec<Hop> = route.iter().map(NodeDescriptor::hop).collect();
        let packet = SphinxPacket::seal(&hops, &envelope.to_bytes())
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
        self.reader.fetch_since(cursor)
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
        let packet = SphinxPacket::seal(&path, b"routed hello").unwrap();
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
        let newcomer = NodeDescriptor {
            id: [9u8; NODE_ID_LEN],
            public: [8u8; 32],
            mix_addr: "127.0.0.1:6100".parse().unwrap(),
            provider_addr: None,
        };
        announce(node.mix_addr, std::slice::from_ref(&newcomer)).unwrap();
        // Give the server a moment to merge.
        for _ in 0..100 {
            if dir.snapshot().len() == 2 {
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }
        assert!(dir.snapshot().iter().any(|n| n.id == [9u8; NODE_ID_LEN]));
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
