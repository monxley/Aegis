//! # aegis-mix — the Aegis mixnet
//!
//! Wires [`aegis_net`]'s Sphinx onion routing into a real, networked layer and
//! plugs it into the send path.
//!
//! - [`MixService`] is a **mix node**: it listens for Sphinx packets, peels one
//!   layer, and either forwards to the next hop or — if it is the exit — hands
//!   the recovered Aegis envelope to a [`Deliver`] sink (e.g. its mailbox). A
//!   node run by the project or a volunteer combines this with a blind
//!   mailbox server; end users run nothing.
//! - [`MixnetStore`] is a [`MailboxStore`] whose `put` **onion-routes** an
//!   envelope through a random path of mixes to a provider (so no single node
//!   links the sender to the deposited message), while `fetch_since` reads from
//!   that provider as before. Because it is a `MailboxStore`, an
//!   `AegisClient`/`AegisApp` uses it with no other change.
//!
//! Receive-path anonymity (polling the provider over the mixnet) and Loopix
//! cover traffic + delays are the next increment; this crate is the routing they
//! build on.

use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream, ToSocketAddrs};
use std::sync::{Arc, Mutex};
use std::thread;

use aegis_crypto::fill_random;
use aegis_mailbox::{Envelope, MailboxError, MailboxStore};
use aegis_net::{Hop, MixNode, ProcessedPacket, SphinxPacket, NODE_ID_LEN, PACKET_LEN};

/// The public description of a mixnet node: its Sphinx id + key (from
/// [`MixNode::public_hop`]) and the network address peers reach it at.
#[derive(Clone, Debug)]
pub struct NodeInfo {
    pub id: [u8; NODE_ID_LEN],
    pub public: [u8; 32],
    pub addr: SocketAddr,
}

impl NodeInfo {
    /// Build from a mix node's public hop and its address.
    pub fn new(hop: Hop, addr: SocketAddr) -> Self {
        NodeInfo {
            id: hop.id,
            public: hop.public,
            addr,
        }
    }
    fn hop(&self) -> Hop {
        Hop {
            id: self.id,
            public: self.public,
        }
    }
}

/// Maps a mix's id to the address to forward to — the routing table a running
/// mix consults for the next hop.
#[derive(Clone, Default)]
pub struct Directory {
    map: HashMap<[u8; NODE_ID_LEN], SocketAddr>,
}

impl Directory {
    pub fn new() -> Self {
        Directory {
            map: HashMap::new(),
        }
    }
    /// Build a directory from the nodes a mix may forward to.
    pub fn from_nodes(nodes: &[NodeInfo]) -> Self {
        let mut d = Directory::new();
        for n in nodes {
            d.map.insert(n.id, n.addr);
        }
        d
    }
    pub fn insert(&mut self, id: [u8; NODE_ID_LEN], addr: SocketAddr) {
        self.map.insert(id, addr);
    }
    fn addr(&self, id: &[u8; NODE_ID_LEN]) -> Option<SocketAddr> {
        self.map.get(id).copied()
    }
}

/// Send one Sphinx packet to a hop: connect, write the fixed-size packet, close.
/// One packet per connection keeps every exchange identical in size.
pub fn dispatch(addr: impl ToSocketAddrs, packet: &SphinxPacket) -> io::Result<()> {
    let mut stream = TcpStream::connect(addr)?;
    stream.write_all(&packet.to_bytes())?;
    stream.flush()
}

/// What an exit mix does with a recovered payload — normally: decode the Aegis
/// envelope and store it in the node's mailbox.
pub trait Deliver: Send + Sync {
    fn deliver(&self, payload: Vec<u8>);
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

/// A networked Sphinx mix node.
pub struct MixService<D: Deliver> {
    node: MixNode,
    directory: Directory,
    deliver: D,
}

impl<D: Deliver + 'static> MixService<D> {
    pub fn new(node: MixNode, directory: Directory, deliver: D) -> Self {
        MixService {
            node,
            directory,
            deliver,
        }
    }

    /// Serve forever: accept connections, process one packet each, forward or
    /// deliver. Blocks; run it on its own thread.
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
        let mut buf = [0u8; PACKET_LEN];
        stream.read_exact(&mut buf)?;
        let Some(packet) = SphinxPacket::from_bytes(&buf) else {
            return Ok(()); // wrong size — drop
        };
        match self.node.process(&packet) {
            Ok(ProcessedPacket::Forward { next, packet }) => {
                if let Some(addr) = self.directory.addr(&next) {
                    let _ = dispatch(addr, &packet); // best-effort forward
                }
            }
            Ok(ProcessedPacket::Deliver { payload }) => self.deliver.deliver(payload),
            Err(_) => {} // bad MAC / degenerate — drop silently
        }
        Ok(())
    }
}

/// A [`MailboxStore`] that **sends through the mixnet** and **reads from a
/// provider**. Drop-in for the plain relay store: `put` onion-routes the
/// envelope through a random path of mixes ending at the exit provider; the
/// send therefore never reaches any node that also knows the sender's address.
/// `fetch_since` polls the provider directly (receive-path anonymity is a later
/// increment).
pub struct MixnetStore<P: MailboxStore> {
    provider: P,
    pool: Vec<NodeInfo>,
    exit: NodeInfo,
    hops: usize,
}

impl<P: MailboxStore> MixnetStore<P> {
    /// * `provider` — where received mail is polled from (e.g. a `CiphraStore`).
    /// * `pool` — candidate intermediate mixes to route through.
    /// * `exit` — the provider node that stores the delivered envelope (the
    ///   route always ends here; its mailbox is what `provider` reads).
    /// * `hops` — how many mixes to pick from `pool` before the exit. Clamped so
    ///   the whole path fits [`aegis_net::MAX_HOPS`].
    pub fn new(provider: P, pool: Vec<NodeInfo>, exit: NodeInfo, hops: usize) -> Self {
        let max_mid = aegis_net::MAX_HOPS.saturating_sub(1);
        let hops = hops.min(max_mid).min(pool.len());
        MixnetStore {
            provider,
            pool,
            exit,
            hops,
        }
    }

    /// A fresh random path of `NodeInfo`s ending at the exit provider.
    fn pick_route(&self) -> Vec<NodeInfo> {
        let mut chosen = choose(&self.pool, self.hops);
        chosen.push(self.exit.clone());
        chosen
    }
}

impl<P: MailboxStore> MailboxStore for MixnetStore<P> {
    fn put(&mut self, envelope: Envelope) -> Result<(), MailboxError> {
        let route = self.pick_route();
        let hops: Vec<Hop> = route.iter().map(NodeInfo::hop).collect();
        let packet = SphinxPacket::seal(&hops, &envelope.to_bytes())
            .map_err(|e| MailboxError(format!("sphinx seal: {e}")))?;
        // Dispatch to the first hop; each hop forwards to the next.
        dispatch(route[0].addr, &packet).map_err(|e| MailboxError(format!("dispatch: {e}")))?;
        Ok(())
    }

    fn fetch_since(&self, cursor: usize) -> Result<(usize, Vec<Envelope>), MailboxError> {
        self.provider.fetch_since(cursor)
    }
}

/// Pick `k` distinct nodes from `pool` using OS randomness (a partial
/// Fisher–Yates shuffle). Returns fewer than `k` only if the pool is smaller.
fn choose(pool: &[NodeInfo], k: usize) -> Vec<NodeInfo> {
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
    use std::net::TcpListener;

    /// Spawn a mix node backed by `deliver`, returning its NodeInfo.
    fn spawn_mix(seed: u8, directory: Directory, deliver: impl Deliver + 'static) -> NodeInfo {
        let node = MixNode::from_seed(&[seed; 32]);
        let info = NodeInfo::new(
            node.public_hop(),
            "127.0.0.1:0".parse().unwrap(), // replaced below
        );
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        thread::spawn(move || {
            let _ = MixService::new(node, directory, deliver).serve(listener);
        });
        NodeInfo { addr, ..info }
    }

    // A Deliver that just records payloads, for the pure-routing test.
    struct Collect(Arc<Mutex<Vec<Vec<u8>>>>);
    impl Deliver for Collect {
        fn deliver(&self, payload: Vec<u8>) {
            self.0.lock().unwrap().push(payload);
        }
    }

    #[test]
    fn a_packet_routes_through_three_networked_mixes() {
        // Build the exit first (it delivers), then the interior mixes whose
        // directories point forward. Bring them up back-to-front so each knows
        // the next hop's address.
        let got = Arc::new(Mutex::new(Vec::new()));
        let exit = spawn_mix(3, Directory::new(), Collect(Arc::clone(&got)));
        let mid = spawn_mix(
            2,
            Directory::from_nodes(std::slice::from_ref(&exit)),
            Collect(got.clone()),
        );
        let entry = spawn_mix(
            1,
            Directory::from_nodes(std::slice::from_ref(&mid)),
            Collect(got.clone()),
        );

        let path = [entry.hop(), mid.hop(), exit.hop()];
        let packet = SphinxPacket::seal(&path, b"routed hello").unwrap();
        dispatch(entry.addr, &packet).unwrap();

        // Give the async forwards a moment to complete.
        wait_for(&got, 1);
        assert_eq!(got.lock().unwrap()[0], b"routed hello");
    }

    #[test]
    fn mixnet_store_delivers_an_envelope_to_the_provider_mailbox() {
        // The exit writes into a shared mailbox; the store reads from it.
        let mailbox = Arc::new(Mutex::new(InMemoryStore::new()));
        let exit = spawn_mix(30, Directory::new(), MailboxDeliver(Arc::clone(&mailbox)));
        let mid = spawn_mix(
            20,
            Directory::from_nodes(std::slice::from_ref(&exit)),
            Collect(Arc::new(Mutex::new(Vec::new()))),
        );

        // A store that routes entry→mid→exit, reading from the same mailbox.
        let reader = SharedRead(Arc::clone(&mailbox));
        let mut store = MixnetStore::new(reader, vec![mid.clone()], exit.clone(), 1);

        let envelope = Envelope::from_bytes(&sample_envelope()).unwrap();
        store.put(envelope).unwrap();

        wait_for_mailbox(&mailbox, 1);
        let (_, got) = store.fetch_since(0).unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].to_bytes(), sample_envelope());
    }

    // --- test helpers ---

    /// A MailboxStore that reads through a shared in-memory mailbox (so the test
    /// store and the exit node see the same messages).
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
        // addr_tag(16) ‖ view_tag(1) ‖ R(32) ‖ ciphertext
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
            thread::sleep(std::time::Duration::from_millis(10));
        }
        panic!("timed out waiting for {n} delivery(ies)");
    }

    fn wait_for_mailbox(m: &Arc<Mutex<InMemoryStore>>, n: usize) {
        for _ in 0..200 {
            if m.lock().unwrap().fetch_since(0).unwrap().1.len() >= n {
                return;
            }
            thread::sleep(std::time::Duration::from_millis(10));
        }
        panic!("timed out waiting for mailbox");
    }
}
