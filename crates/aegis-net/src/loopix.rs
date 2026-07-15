//! Loopix mixing and cover traffic (see `docs/CRYPTO_MATH.md` §6). Sphinx
//! (this crate's core) hides *routing*; Loopix hides *timing*, defeating an
//! adversary who watches when packets enter and leave.
//!
//! Two mechanisms:
//!
//! - **Poisson mixing** ([`MixQueue`]): each mix delays every packet
//!   independently by an `Exp(μ)` time. Under Poisson input the output is also
//!   Poisson and independent of the input timing (§6.1), so observing outputs
//!   reveals nothing about which input produced which output.
//! - **Cover traffic** ([`PoissonEmitter`], [`drop_cover`], [`loop_cover`]):
//!   clients emit real, drop, and loop packets as independent Poisson streams
//!   that superpose into one Poisson stream (§6.2), so "is Alice sending right
//!   now?" is unanswerable against the constant background. Loop packets routed
//!   back to the sender also detect active dropping/delaying attacks (§6.3).
//!
//! Timing here is expressed in abstract seconds against a caller-supplied clock,
//! so the mechanism is testable deterministically; wiring it to a real clock and
//! network is the application's job.

use crate::rng::Rng;
use crate::{Hop, SphinxError, SphinxPacket};

/// Sample an `Exp(rate)` delay (mean `1/rate`) from `rng`. `rate` must be > 0.
pub fn exp_delay(rate: f64, rng: &mut impl Rng) -> f64 {
    debug_assert!(rate > 0.0, "rate must be positive");
    // u ∈ (0, 1]; 1 - next_f64() avoids ln(0).
    let u = 1.0 - rng.next_f64();
    -u.ln() / rate
}

/// A Poisson mix: an M/M/∞ queue that releases each enqueued item after an
/// independent `Exp(μ)` delay. Generic over the item so it is easy to test with
/// plain values; in the mixnet the item is a `(next_hop, SphinxPacket)`.
pub struct MixQueue<T> {
    rate: f64,
    pending: Vec<(f64, T)>,
}

impl<T> MixQueue<T> {
    /// A new mix with per-packet delay rate `mu` (mean delay `1/mu`).
    pub fn new(mu: f64) -> Self {
        MixQueue {
            rate: mu,
            pending: Vec::new(),
        }
    }

    /// Enqueue `item` at time `now`, drawing an independent `Exp(μ)` delay.
    pub fn enqueue(&mut self, item: T, now: f64, rng: &mut impl Rng) {
        let release = now + exp_delay(self.rate, rng);
        self.pending.push((release, item));
    }

    /// Remove and return every item whose release time is `<= now`, in
    /// ascending release order (which need not match insertion order — that is
    /// the mixing).
    pub fn pop_due(&mut self, now: f64) -> Vec<T> {
        let mut due: Vec<(f64, T)> = Vec::new();
        let mut keep: Vec<(f64, T)> = Vec::new();
        for (release, item) in self.pending.drain(..) {
            if release <= now {
                due.push((release, item));
            } else {
                keep.push((release, item));
            }
        }
        self.pending = keep;
        due.sort_by(|a, b| a.0.partial_cmp(&b.0).expect("finite release times"));
        due.into_iter().map(|(_, item)| item).collect()
    }

    /// Number of packets still held.
    pub fn len(&self) -> usize {
        self.pending.len()
    }

    /// Whether the mix currently holds no packets.
    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }
}

/// A Poisson emitter: yields inter-emission delays for a stream of rate
/// `lambda`. Independent emitters superpose into one Poisson stream, which is
/// what makes real and cover traffic indistinguishable in aggregate.
pub struct PoissonEmitter {
    lambda: f64,
}

impl PoissonEmitter {
    /// A new emitter of rate `lambda` (mean gap `1/lambda`).
    pub fn new(lambda: f64) -> Self {
        PoissonEmitter { lambda }
    }

    /// The delay until the next emission.
    pub fn next_delay(&self, rng: &mut impl Rng) -> f64 {
        exp_delay(self.lambda, rng)
    }
}

/// Fixed payload marker carried by drop-cover packets. On the wire a drop packet
/// is a normal Sphinx packet; only its exit sees this and discards it.
pub const DROP_PAYLOAD: &[u8] = b"aegis/loopix/drop";

/// Choose `hops` mixes at random (with replacement) from `mixes`.
fn random_path(mixes: &[Hop], hops: usize, rng: &mut impl Rng) -> Vec<Hop> {
    (0..hops)
        .map(|_| mixes[(rng.next_u64() as usize) % mixes.len()])
        .collect()
}

/// Build a **drop-cover** packet: a real Sphinx packet through a random path
/// whose exit simply discards the payload. Indistinguishable on the wire from a
/// payload-carrying packet, it fills the sender's Poisson stream when there is
/// nothing real to send.
pub fn drop_cover(
    mixes: &[Hop],
    hops: usize,
    rng: &mut impl Rng,
) -> Result<SphinxPacket, SphinxError> {
    let path = random_path(mixes, hops, rng);
    SphinxPacket::seal(&path, DROP_PAYLOAD)
}

/// Build a **loop-cover** packet routed through a random path and back to
/// `self_hop` (the sender's own mix), carrying `token` so the sender recognizes
/// it on return. A loop that fails to come back at the expected rate signals an
/// active dropping/delaying attack (§6.3). `hops` is the number of *foreign*
/// mixes before the return; `hops + 1` must be `<= MAX_HOPS`.
pub fn loop_cover(
    mixes: &[Hop],
    hops: usize,
    self_hop: Hop,
    token: &[u8],
    rng: &mut impl Rng,
) -> Result<SphinxPacket, SphinxError> {
    let mut path = random_path(mixes, hops, rng);
    path.push(self_hop);
    SphinxPacket::seal(&path, token)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rng::ChaChaRng;
    use crate::{MixNode, ProcessedPacket};

    #[test]
    fn exp_delay_has_the_right_mean() {
        let mut rng = ChaChaRng::from_seed([9u8; 32]);
        let rate = 2.0;
        let n = 50_000;
        let mut sum = 0.0;
        for _ in 0..n {
            sum += exp_delay(rate, &mut rng);
        }
        let mean = sum / n as f64;
        // Deterministic seed, so this tolerance is stable, not flaky.
        assert!((mean - 0.5).abs() < 0.02, "mean = {mean}");
    }

    #[test]
    fn poisson_emitter_has_the_right_mean_gap() {
        let mut rng = ChaChaRng::from_seed([3u8; 32]);
        let emitter = PoissonEmitter::new(5.0);
        let n = 50_000;
        let mut sum = 0.0;
        for _ in 0..n {
            sum += emitter.next_delay(&mut rng);
        }
        assert!((sum / n as f64 - 0.2).abs() < 0.01);
    }

    #[test]
    fn mix_releases_everything_eventually_and_only_when_due() {
        let mut rng = ChaChaRng::from_seed([1u8; 32]);
        let mut mix = MixQueue::new(1.0);
        for i in 0..100u32 {
            mix.enqueue(i, 0.0, &mut rng);
        }
        assert_eq!(mix.len(), 100);
        // Nothing is due before any time passes with overwhelming probability.
        let early = mix.pop_due(0.0);
        assert!(early.len() < 100);
        // By a far-future time everything has been released exactly once.
        let mut seen = early;
        seen.extend(mix.pop_due(1_000_000.0));
        assert_eq!(seen.len(), 100);
        assert!(mix.is_empty());
        seen.sort_unstable();
        assert_eq!(seen, (0..100).collect::<Vec<_>>());
    }

    #[test]
    fn mixing_can_reorder_relative_to_insertion() {
        // Over many packets the release order differs from insertion order —
        // the timing decorrelation that hides which input became which output.
        let mut rng = ChaChaRng::from_seed([42u8; 32]);
        let mut mix = MixQueue::new(1.0);
        for i in 0..200u32 {
            mix.enqueue(i, 0.0, &mut rng);
        }
        let released = mix.pop_due(1_000_000.0);
        assert_eq!(released.len(), 200);
        assert_ne!(
            released,
            (0..200).collect::<Vec<_>>(),
            "no reordering at all"
        );
    }

    fn mixes(n: usize) -> Vec<MixNode> {
        (0..n)
            .map(|i| MixNode::from_seed(&[(i as u8).wrapping_add(1); 32]))
            .collect()
    }

    #[test]
    fn drop_cover_routes_like_a_real_packet() {
        let mixes = mixes(4);
        let hops: Vec<_> = mixes.iter().map(|m| m.public_hop()).collect();
        let mut rng = ChaChaRng::from_seed([5u8; 32]);
        let mut pkt = drop_cover(&hops, 3, &mut rng).unwrap();
        // It processes through mixes exactly like a payload packet.
        let mut delivered = false;
        for _ in 0..MAX_HOPS_LOCAL {
            // find which mix it is addressed to would need the routing; instead
            // try each mix until one accepts (MAC gate), mirroring a relay.
            let mut advanced = false;
            for mix in &mixes {
                if let Ok(result) = mix.process(&pkt) {
                    match result {
                        ProcessedPacket::Forward { packet, .. } => {
                            pkt = *packet;
                            advanced = true;
                            break;
                        }
                        ProcessedPacket::Deliver { payload } => {
                            assert_eq!(payload, DROP_PAYLOAD);
                            delivered = true;
                            advanced = true;
                            break;
                        }
                        ProcessedPacket::DeliverReply { .. } => unreachable!(),
                    }
                }
            }
            assert!(advanced, "packet stalled");
            if delivered {
                break;
            }
        }
        assert!(delivered);
    }

    #[test]
    fn loop_cover_returns_to_the_sender() {
        let mixes = mixes(4);
        let hops: Vec<_> = mixes.iter().map(|m| m.public_hop()).collect();
        let me = &mixes[0]; // the sender's own mix
        let token = b"loop-token-42";
        let mut rng = ChaChaRng::from_seed([8u8; 32]);
        let mut pkt = loop_cover(&hops, 3, me.public_hop(), token, &mut rng).unwrap();

        // Route it; it must come back to `me` and deliver the token.
        let mut delivered = None;
        for _ in 0..MAX_HOPS_LOCAL {
            let mut advanced = false;
            for mix in &mixes {
                if let Ok(result) = mix.process(&pkt) {
                    match result {
                        ProcessedPacket::Forward { packet, .. } => {
                            pkt = *packet;
                            advanced = true;
                            break;
                        }
                        ProcessedPacket::Deliver { payload } => {
                            delivered = Some(payload);
                            advanced = true;
                            break;
                        }
                        ProcessedPacket::DeliverReply { .. } => unreachable!(),
                    }
                }
            }
            assert!(advanced, "loop packet stalled");
            if delivered.is_some() {
                break;
            }
        }
        assert_eq!(delivered.as_deref(), Some(&token[..]));
    }

    const MAX_HOPS_LOCAL: usize = 8;
}
