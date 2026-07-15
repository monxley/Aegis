//! A small random-number source for Loopix's Poisson sampling.
//!
//! Timing decisions (mix delays, cover-traffic schedules) need uniform randoms,
//! not just key bytes. This module exposes an [`Rng`] trait with a deterministic
//! ChaCha20-based implementation (reproducible from a seed — so timing tests are
//! not flaky) and an OS-seeded constructor for production.

use aegis_crypto::{chacha20, fill_random};

/// A source of uniform random values.
pub trait Rng {
    /// A uniform 64-bit value.
    fn next_u64(&mut self) -> u64;

    /// A uniform `f64` in `[0, 1)` (53-bit precision).
    fn next_f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / ((1u64 << 53) as f64)
    }
}

/// A deterministic ChaCha20 keystream RNG. Reproducible from its 32-byte seed.
pub struct ChaChaRng {
    key: [u8; 32],
    counter: u32,
    buffer: [u8; 64],
    offset: usize,
}

impl ChaChaRng {
    /// Seed the RNG deterministically (for reproducible tests).
    pub fn from_seed(seed: [u8; 32]) -> Self {
        ChaChaRng {
            key: seed,
            counter: 0,
            buffer: [0u8; 64],
            offset: 64, // force a refill on first use
        }
    }

    /// Seed the RNG from OS randomness (for production).
    pub fn from_os() -> Self {
        let mut seed = [0u8; 32];
        fill_random(&mut seed);
        Self::from_seed(seed)
    }

    fn refill(&mut self) {
        self.buffer = chacha20::block(&self.key, self.counter, &[0u8; 12]);
        self.counter = self.counter.wrapping_add(1);
        self.offset = 0;
    }
}

impl Rng for ChaChaRng {
    fn next_u64(&mut self) -> u64 {
        if self.offset + 8 > self.buffer.len() {
            self.refill();
        }
        let mut bytes = [0u8; 8];
        bytes.copy_from_slice(&self.buffer[self.offset..self.offset + 8]);
        self.offset += 8;
        u64::from_le_bytes(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_deterministic_from_a_seed() {
        let mut a = ChaChaRng::from_seed([7u8; 32]);
        let mut b = ChaChaRng::from_seed([7u8; 32]);
        for _ in 0..100 {
            assert_eq!(a.next_u64(), b.next_u64());
        }
    }

    #[test]
    fn f64_is_in_unit_interval() {
        let mut rng = ChaChaRng::from_seed([1u8; 32]);
        for _ in 0..10_000 {
            let x = rng.next_f64();
            assert!((0.0..1.0).contains(&x));
        }
    }
}
