//! Best-effort zeroization of secret material. Adapted from Ciphra's
//! `ciphra-crypto::zeroize` (Apache-2.0).
//!
//! Secret key bytes are overwritten when their holder is dropped. This is
//! **defense in depth, not a guarantee**: the compiler may still leave
//! spilled or moved copies. The volatile writes below stop the obvious
//! long-lived copy from lingering and resist dead-store elimination.

use core::sync::atomic::{compiler_fence, Ordering};

/// Overwrite `buf` with zeros using volatile writes the optimizer may not
/// elide, then a fence so the writes are not reordered past it.
pub(crate) fn secure_zero(buf: &mut [u8]) {
    for byte in buf.iter_mut() {
        // SAFETY: `byte` is a valid, aligned, writable `u8`.
        unsafe { core::ptr::write_volatile(byte, 0) };
    }
    compiler_fence(Ordering::SeqCst);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zeros_the_buffer() {
        let mut secret = [0xa5u8; 64];
        secure_zero(&mut secret);
        assert_eq!(secret, [0u8; 64]);
    }
}
