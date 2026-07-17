//! A 24-word recovery phrase for the 32-byte master seed.
//!
//! Same construction as BIP-39 — 256 bits of entropy plus an 8-bit SHA-256
//! checksum, split into 24 groups of 11 bits, one word per group — but over a
//! **self-contained, generated wordlist** so Aegis carries no external data and
//! stays zero-dependency. The 2048 words are pronounceable
//! consonant-vowel-consonant syllables (16 × 8 × 16 = 2^11), unique and
//! space-separated, so a phrase round-trips exactly and a single typo trips the
//! checksum.

use crate::sha256;

const CONSONANTS: [&str; 16] = [
    "b", "c", "d", "f", "g", "h", "j", "k", "l", "m", "n", "p", "r", "s", "t", "v",
];
const VOWELS: [&str; 8] = ["a", "e", "i", "o", "u", "ai", "ou", "ei"];

/// The word for an 11-bit index: 4 bits pick the first consonant, 3 the vowel,
/// 4 the last consonant.
fn word(index: u16) -> String {
    let c1 = ((index >> 7) & 0xF) as usize;
    let v = ((index >> 4) & 0x7) as usize;
    let c2 = (index & 0xF) as usize;
    format!("{}{}{}", CONSONANTS[c1], VOWELS[v], CONSONANTS[c2])
}

/// Parse a word back to its 11-bit index. The first and last chars are the
/// consonants; everything between is the vowel — unambiguous, since consonants
/// and vowels are disjoint.
fn index_of(w: &str) -> Option<u16> {
    let w = w.trim().to_lowercase();
    if w.len() < 3 || !w.is_ascii() {
        return None;
    }
    let c1 = CONSONANTS.iter().position(|&c| c == &w[0..1])? as u16;
    let c2 = CONSONANTS.iter().position(|&c| c == &w[w.len() - 1..])? as u16;
    let v = VOWELS.iter().position(|&x| x == &w[1..w.len() - 1])? as u16;
    Some((c1 << 7) | (v << 4) | c2)
}

/// Encode a 32-byte seed as a 24-word recovery phrase.
pub fn seed_to_phrase(seed: &[u8; 32]) -> String {
    // 256 entropy bits ‖ 8 checksum bits = 264 = 24 × 11.
    let checksum = sha256(seed)[0];
    let mut bits: Vec<bool> = Vec::with_capacity(264);
    for &byte in seed {
        for i in (0..8).rev() {
            bits.push((byte >> i) & 1 == 1);
        }
    }
    for i in (0..8).rev() {
        bits.push((checksum >> i) & 1 == 1);
    }
    let mut words = Vec::with_capacity(24);
    for group in bits.chunks(11) {
        let mut idx = 0u16;
        for &bit in group {
            idx = (idx << 1) | bit as u16;
        }
        words.push(word(idx));
    }
    words.join(" ")
}

/// Decode a recovery phrase back to the seed. Returns `None` on the wrong word
/// count, an unknown word, or a failed checksum (a typo).
pub fn phrase_to_seed(phrase: &str) -> Option<[u8; 32]> {
    let words: Vec<&str> = phrase.split_whitespace().collect();
    if words.len() != 24 {
        return None;
    }
    let mut bits: Vec<bool> = Vec::with_capacity(264);
    for w in &words {
        let idx = index_of(w)?;
        for j in (0..11).rev() {
            bits.push((idx >> j) & 1 == 1);
        }
    }
    let mut seed = [0u8; 32];
    for (i, byte) in seed.iter_mut().enumerate() {
        let mut b = 0u8;
        for j in 0..8 {
            b = (b << 1) | bits[i * 8 + j] as u8;
        }
        *byte = b;
    }
    let mut checksum = 0u8;
    for j in 0..8 {
        checksum = (checksum << 1) | bits[256 + j] as u8;
    }
    if sha256(&seed)[0] != checksum {
        return None;
    }
    Some(seed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_and_has_24_words() {
        let seed = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
            16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
        ];
        let phrase = seed_to_phrase(&seed);
        assert_eq!(phrase.split_whitespace().count(), 24);
        assert_eq!(phrase_to_seed(&phrase), Some(seed));
    }

    #[test]
    fn every_seed_round_trips() {
        for k in 0..64u8 {
            let seed = [k.wrapping_mul(7).wrapping_add(1); 32];
            let phrase = seed_to_phrase(&seed);
            assert_eq!(phrase_to_seed(&phrase), Some(seed), "seed {k}");
        }
    }

    #[test]
    fn rejects_bad_checksum_and_length() {
        let seed = [9u8; 32];
        let phrase = seed_to_phrase(&seed);
        let mut words: Vec<&str> = phrase.split_whitespace().collect();
        // Swap the first word for a different valid word → checksum fails.
        let other = word((index_of(words[0]).unwrap() + 1) % 2048);
        words[0] = &other;
        assert_eq!(phrase_to_seed(&words.join(" ")), None);
        // Wrong length.
        assert_eq!(phrase_to_seed("bab bab bab"), None);
        // Unknown word.
        assert_eq!(phrase_to_seed(&"zzz ".repeat(24)), None);
    }
}
