//! Operating-system randomness.
//!
//! Preference order:
//! 1. the **`getrandom(2)` syscall** on Linux/Android (x86_64 / aarch64) — it
//!    needs no file descriptor and blocks until the kernel CSPRNG is seeded, so
//!    it can't be starved by fd exhaustion or return unseeded output;
//! 2. otherwise a single, lazily-opened `/dev/urandom` handle, reused across
//!    calls so we never churn descriptors.
//!
//! Either way, failure to obtain randomness **panics** — proceeding with
//! predictable key material would be strictly worse than crashing.

use std::fs::File;
use std::io::Read;
use std::sync::OnceLock;

/// Fill `buf` with cryptographically secure random bytes.
pub fn fill_random(buf: &mut [u8]) {
    if buf.is_empty() {
        return;
    }
    if getrandom_fill(buf) {
        return;
    }
    urandom_fill(buf);
}

/// Try to fill `buf` via `getrandom(2)`. Returns `false` (so the caller falls
/// back to `/dev/urandom`) if the syscall is unavailable on this target or the
/// kernel reports it is not implemented.
#[cfg(all(
    any(target_os = "linux", target_os = "android"),
    any(target_arch = "x86_64", target_arch = "aarch64")
))]
fn getrandom_fill(buf: &mut [u8]) -> bool {
    let mut filled = 0;
    while filled < buf.len() {
        // SAFETY: valid writable pointer/length for the sub-slice being filled.
        let ret = unsafe { getrandom_syscall(buf[filled..].as_mut_ptr(), buf.len() - filled) };
        if ret > 0 {
            filled += ret as usize;
        } else if ret == -4 {
            // EINTR before any bytes were written — retry.
            continue;
        } else {
            // ENOSYS (old kernel) or any other error: fall back.
            return false;
        }
    }
    true
}

#[cfg(not(all(
    any(target_os = "linux", target_os = "android"),
    any(target_arch = "x86_64", target_arch = "aarch64")
)))]
fn getrandom_fill(_buf: &mut [u8]) -> bool {
    false
}

#[cfg(all(
    any(target_os = "linux", target_os = "android"),
    target_arch = "x86_64"
))]
unsafe fn getrandom_syscall(ptr: *mut u8, len: usize) -> isize {
    let ret: isize;
    core::arch::asm!(
        "syscall",
        inlateout("rax") 318isize => ret, // SYS_getrandom
        in("rdi") ptr,
        in("rsi") len,
        in("rdx") 0usize,                 // flags = 0: block until seeded
        lateout("rcx") _,                 // clobbered by syscall
        lateout("r11") _,                 // clobbered by syscall
        options(nostack),
    );
    ret
}

#[cfg(all(
    any(target_os = "linux", target_os = "android"),
    target_arch = "aarch64"
))]
unsafe fn getrandom_syscall(ptr: *mut u8, len: usize) -> isize {
    let ret: isize;
    core::arch::asm!(
        "svc 0",
        in("x8") 278isize,                // SYS_getrandom
        inlateout("x0") ptr => ret,
        in("x1") len,
        in("x2") 0usize,                  // flags = 0
        options(nostack),
    );
    ret
}

/// Fill from a single, lazily-opened `/dev/urandom` handle (reused across
/// calls). `&File` implements `Read`, and `/dev/urandom` is a character device
/// with no offset, so concurrent reads are safe and each returns fresh bytes.
fn urandom_fill(buf: &mut [u8]) {
    static SOURCE: OnceLock<File> = OnceLock::new();
    let mut src: &File = SOURCE.get_or_init(|| {
        File::open("/dev/urandom")
            .expect("cannot open /dev/urandom: no secure randomness available")
    });
    src.read_exact(buf)
        .expect("failed to read from /dev/urandom");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fills_and_varies() {
        let mut a = [0u8; 32];
        let mut b = [0u8; 32];
        fill_random(&mut a);
        fill_random(&mut b);
        // 2^-256 false-negative probability is acceptable.
        assert_ne!(a, b);
        assert_ne!(a, [0u8; 32]);
    }

    #[test]
    fn fills_a_large_buffer_fully() {
        // Larger than any single request the crate makes; exercises the fill
        // loop and guarantees no trailing bytes are left un-written.
        let mut big = [0u8; 4096];
        fill_random(&mut big);
        assert_ne!(&big[4064..], &[0u8; 32][..]);
    }

    #[test]
    fn empty_buffer_is_a_noop() {
        let mut empty: [u8; 0] = [];
        fill_random(&mut empty);
    }

    #[test]
    fn urandom_fallback_path_works() {
        // Exercise the fallback directly, independent of the syscall path.
        let mut a = [0u8; 32];
        urandom_fill(&mut a);
        assert_ne!(a, [0u8; 32]);
    }
}
