# Aegis — Internal Security Review

**Scope:** the Aegis messaging protocol and its Rust implementation
(`crates/aegis-*`), plus the at-rest / device-hardening layer in `aegis-api`.
**Method:** manual source review of the cryptographic core, key-derivation,
AEAD/nonce handling, the PQ handshake/ratchet, stealth addressing, the mailbox
envelope, and the Sphinx/Loopix network layer.
**Date:** 2026-07 · **Reviewer:** internal.

> ### This is NOT the external audit
> AEGIS_PROTOCOL.md §11 and the roadmap both list an **independent external
> security audit as a release blocker**, and this document does not replace it.
> Aegis *implements* well-studied designs (X3DH/PQXDH, Double Ratchet, ML-KEM,
> ML-DSA, Sphinx, Loopix) **from scratch**, and hand-written implementations of
> sound designs are exactly where side-channels and edge-case bugs hide. Treat
> everything below as "found by reading the code carefully," not as a clearance.
> Until a professional audit is done, Aegis makes **no security promises** and
> should be labelled *alpha*.

Findings are rated **High / Medium / Low / Info** by realistic impact against
the threat model in §1 of the protocol.

---

## Summary

| ID | Severity | Area | One line | Status |
|----|----------|------|----------|--------|
| F-1 | **High** | ML-KEM | Decapsulation compares ciphertexts non-constant-time → FO reject timing oracle | ✅ fixed |
| F-2 | **Medium** | Password KDF | PBKDF2-HMAC-SHA256 at 120k iters, not memory-hard — weak vs a seized device | ⚠️ mitigated (600k); Argon2id still TODO |
| F-3 | **Medium** | RNG | Randomness reads `/dev/urandom` via a file handle each call (panic / seeding / sandbox) | ✅ fixed |
| F-4 | **Low** | Stealth scan | `addr_tag` / `view_tag` compared with `==` (non-constant-time) during scanning | ✅ fixed |
| F-5 | **Info** | Whole system | Self-implemented PQ primitives + protocol, validated only by test vectors | 🔒 external audit |
| F-6 | **Info** | Infra | Single seed node = single point of failure and weakens the mix anonymity set | 📋 roadmap 2.1 |

Confirmed-good properties (things that were checked and are correct) are listed
at the end, so this reads as a review and not just a bug list.

---

## F-1 · High · Non-constant-time ciphertext compare in ML-KEM decapsulation

> **Status: ✅ fixed.** `decapsulate()` now compares the full ciphertext with
> `ct_eq_mask` (no early exit) and selects the 32-byte output byte-wise under the
> resulting mask, so neither the compare nor the choice branches on validity. The
> existing `kem_roundtrip_and_implicit_rejection` test covers both mask branches.

**Where:** `crates/aegis-crypto/src/ml_kem.rs`, `decapsulate()`:

```rust
let ct_prime = pke_encrypt(ek_pke, &m_prime, &r);
if ct == ct_prime.as_slice() {   // <-- non-constant-time byte compare
    shared
} else {
    k_bar
}
```

**Problem.** ML-KEM's CCA security comes from the Fujisaki–Okamoto transform:
decapsulation re-encrypts and, on mismatch, returns a *pseudo-random* implicit
rejection key (`k_bar`) so an attacker cannot tell a valid ciphertext from an
invalid one. Rust's `==` on slices **short-circuits on the first differing
byte**, so the time this branch takes leaks *whether* — and roughly *how far
into the ciphertext* — `ct` matched `ct_prime`. That is precisely the
plaintext-checking / decapsulation-failure oracle the FO transform exists to
remove (the class exploited by KyberSlash-style and earlier FO timing attacks).

**Why it matters here.** The ML-KEM prekey (`PQSPK`) is **medium-term and reused
across many initiators** (§3.1), and the ratchet re-uses a rotating KEM key
(§4.2). A reused decapsulation key plus a decapsulation timing oracle is the
standard setup for an adaptive chosen-ciphertext **key-recovery** attack against
the KEM, which would undermine the post-quantum secrecy claim (G4). Exploitation
needs many timed queries to the victim's decapsulation, which the always-on
receive path plausibly exposes.

**Fix.** Compare in constant time — reuse the same idea as the (correct)
Poly1305 `tags_equal`: OR the XOR of every byte and test once at the end. The
comparison must be over the **full** 1088-byte ciphertext with no early return.
Also audit `pke_decrypt` / the NTT reductions for data-dependent branches and
`%`/division on secret coefficients (constant-modulus `%` usually lowers to a
multiply-shift, but confirm on the ARM release target).

---

## F-2 · Medium · Password stretching is under-parameterized and not memory-hard

> **Status: ⚠️ partially fixed.** Vault PBKDF2 iterations raised **120k → 600k**
> (OWASP-2023 floor) with a versioned blob (v2) so existing v1 vaults still open
> and upgrade to v2 on the next re-seal (`legacy_v1_blob_still_opens` test). The
> deeper fix — a **memory-hard KDF (Argon2id)** — is deliberately *not* done here:
> hand-rolling Argon2id zero-dependency under time pressure would be riskier than
> the finding. Tracked as roadmap 2.5.

**Where:** `crates/aegis-api/src/vault.rs` (`ITERATIONS = 120_000`) for the app
password that encrypts the master seed; `crates/aegis-api/src/lib.rs`
(`NOTES_ITERATIONS = 314_159`) for the notes password. Both call
`pbkdf2_sha256`.

**Problem.** The whole app-lock / duress model (§1.4) assumes that a **seized
device** with the encrypted seed vault cannot be brute-forced offline. But:

- **120k PBKDF2-HMAC-SHA256** is below current guidance (OWASP 2023 suggests
  ≥600k for PBKDF2-HMAC-SHA256), so the safety margin is thinner than it looks.
- More fundamentally, **PBKDF2 is not memory-hard** — it is cheap to accelerate
  massively on GPUs/ASICs. Against a realistic phone-seizure adversary with
  offline access to the vault, PBKDF2 is the weakest link, especially for the
  short passwords users actually type.

**Fix.** Move seed/notes/duress vault derivation to **Argon2id** (memory-hard;
tune memory/time to the device budget). If a pure-Rust zero-dep constraint must
hold, `scrypt` is the fallback. At minimum, raise PBKDF2 iterations toward the
current recommendation. Note the notes layer at ~314k is better but still
PBKDF2. (This does not weaken confidentiality of *messages* — only the
at-rest / coercion posture.)

---

## F-3 · Medium · RNG opens `/dev/urandom` as a file on every call

> **Status: ✅ fixed.** `fill_random()` now prefers the **`getrandom(2)` syscall**
> on Linux/Android (x86_64 + aarch64) — no file descriptor, blocks until the
> CSPRNG is seeded — and falls back to a **single lazily-opened, reused**
> `/dev/urandom` handle (no per-call `open`, so no fd churn) on other targets or
> if the syscall returns `ENOSYS`. Both paths are covered by tests. The
> `SecRandomCopyBytes`/`getentropy` path for iOS slots in the same way later.

**Where:** `crates/aegis-crypto/src/rand.rs`, `fill_random()` — `File::open(
"/dev/urandom")` + `read_exact`, and **panics** on failure.

**Problem.** Every key, ephemeral, salt, and nonce in the system ultimately
depends on this one function, and the fixed-nonce safety of the mailbox envelope
(`ENVELOPE_NONCE = [0;12]`, safe *only* because each envelope key is unique)
rests entirely on it never repeating an ephemeral. Reading `/dev/urandom` via a
file descriptor has three real drawbacks versus the `getrandom(2)` syscall:

1. **Availability / DoS.** It needs a free file descriptor and `/dev/urandom`
   present and readable. Under fd exhaustion, a restrictive **Android SELinux**
   context, or a seccomp sandbox that blocks the `open`, it **panics** — a
   crash-on-demand for any code path that draws randomness. `getrandom(2)` needs
   no fd and no filesystem.
2. **Seeding.** `getrandom(2)` (without `GRND_INSECURE`) guarantees the kernel
   CSPRNG is initialized; a raw `/dev/urandom` read can, in principle, return
   output before the pool is seeded (early boot). Low probability at app runtime
   on a phone, but free to eliminate.
3. **Portability.** iOS (roadmap 4.3) has no `/dev/urandom` guarantee; the
   correct call there is `SecRandomCopyBytes` / `getentropy`.

**Fix.** Use `getrandom(2)` / `getentropy` (via the platform syscall behind the
same `fill_random` signature — the module comment already anticipates this).
Keep the panic-on-failure policy (predictable keys must never be used), but make
failure near-impossible rather than fd/sandbox-dependent.

---

## F-4 · Low · Non-constant-time tag comparison during stealth scanning

> **Status: ✅ fixed.** The 16-byte `addr_tag` confirm now uses the new
> constant-time `aegis_crypto::ct_eq`. The 1-byte `view_tag` fast-reject stays a
> plain compare by design (it is a coarse speed optimization, per Monero) and is
> documented as such in the code.

**Where:** `crates/aegis-identity/src/identity.rs` (`recomputed.view_tag ==
address.view_tag && recomputed.addr_tag == address.addr_tag`).

**Problem.** Recipient scanning compares recomputed vs stored `addr_tag`/
`view_tag` with `==`. This is timing-variable. The **real** impact is low: the
`addr_tag` is not a secret the attacker is trying to recover (the *sender*
already computed it from the shared secret), and the attacker would need to time
the recipient's local scan loop. It is a hygiene / defense-in-depth issue, not a
key-recovery oracle like F-1.

**Fix.** Compare the 16-byte `addr_tag` with the constant-time helper for
uniformity. The 1-byte `view_tag` fast-reject is inherently a coarse timing
signal by design (Monero accepts this trade-off for scan speed) — document it
rather than fight it.

---

## F-5 · Info · Self-implemented PQ primitives and protocol

`aegis-crypto` re-implements ML-KEM-768 (FIPS 203), ML-DSA-65 (FIPS 204),
X25519, ChaCha20-Poly1305, SHA-2/3, HKDF/HMAC from scratch, and `aegis-*`
assembles PQXDH, the Double Ratchet, Sphinx and Loopix on top. This is a
deliberate zero-dependency choice, and the primitives are cross-checked against
RFC/FIPS **test vectors** — which proves *functional* correctness but **not**
side-channel resistance, constant-timeness, or resistance to malformed/adaptive
inputs (F-1 is a concrete example of what vectors can't catch). A production
messenger would normally lean on a reviewed library (e.g. a vetted ML-KEM) for
exactly these primitives. This is inherent risk, not a specific bug; it is the
core reason the external audit (roadmap 2.9) is a hard release blocker.

---

## F-6 · Info · Single seed node

The default network bootstraps to one node (`135.181.125.178`). Two consequences:
availability (that node down = the default network is unreachable), and
anonymity — Loopix/Sphinx mixing gives meaningful unlinkability only with a pool
of **independently operated** nodes; with one node there are no real intermediate
hops. Tracked as roadmap item 2.1. Not a code flaw, but it caps the anonymity
guarantee (G7) in practice today.

---

## Confirmed-good (checked and correct)

These were reviewed and found sound — recorded so the review is honest both ways:

- **AEAD tag verification is constant-time** (`poly1305::tags_equal`, used by
  `aead::open`); `open` returns no partial plaintext on failure.
- **AEAD nonce discipline is sound.** The ratchet derives `(key, nonce)` together
  from each unique message key, and the mailbox's fixed all-zero nonce is
  genuinely safe because its key is one-time per envelope (the `(key,nonce)` pair
  never repeats) — *provided* F-3's RNG holds.
- **X25519 is clamped** (`k[0] &= 248; k[31] &= 127; …`) and the **degenerate
  all-zero shared secret is rejected** (RFC 7748 §6.1 contributory check) in both
  stealth addressing and the Sphinx blinding chain.
- **Ratchet headers are bound as AEAD AAD** (sender ratchet key, counters), so
  reorder/replay of a ciphertext fails to open.
- **Hybrid PQ handshake** mixes X25519×4 ‖ ML-KEM through HKDF — the session
  survives unless *both* the classical and the PQ primitive are broken (G4).
- **Sealed sender + one-time stealth tags**: the relay sees only a one-time
  `addr_tag`, an ephemeral `R`, and opaque ciphertext (G5 + G6).
- **Secrets are zeroized on drop** with volatile writes + a compiler fence
  (honestly documented as best-effort, not a guarantee).
- **Duress/decoy vault** is a separate random seed; nothing on disk distinguishes
  it from a fresh real account.

---

## Fix status

Addressed in this branch (the code changes are constant-time / behaviour-
preserving and covered by tests):

- ✅ **F-1** — constant-time ML-KEM decapsulation (masked compare + byte-wise
  select). The key-recovery-class oracle is closed.
- ✅ **F-3** — `getrandom(2)` RNG with a cached `/dev/urandom` fallback.
- ✅ **F-4** — constant-time `addr_tag` compare via `aegis_crypto::ct_eq`.
- ⚠️ **F-2** — PBKDF2 raised to 600k with a versioned, backward-compatible vault.
  The memory-hard **Argon2id** upgrade is intentionally left for dedicated work
  (a vetted implementation, not a rushed from-scratch one) → roadmap 2.5.

Still open (not code-level quick fixes):

- 🔒 **F-5** — the external security audit (roadmap 2.9). This internal review is
  not a substitute.
- 📋 **F-6** — multi-node rollout (roadmap 2.1).
