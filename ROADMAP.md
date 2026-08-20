# Aegis — Development Roadmap

This is the forward-looking plan. For **what already ships**, see the status
table in the [README](README.md) and the protocol design in
[AEGIS_PROTOCOL.md](AEGIS_PROTOCOL.md). For known security gaps and their
priority, see [SECURITY_AUDIT.md](SECURITY_AUDIT.md).

**Where the project stands:** all five protocol layers are implemented and
tested (10 Rust crates, ~160 tests), with a Flutter app (Android-first) and
turnkey node/APK deploy scripts. The foundation is strong. The gaps are in
**message content** (text only), **infrastructure** (a single seed node), and
**verification** (no working CI, no external audit). The roadmap is ordered to
close those in that order of leverage.

Status legend: 🔜 next · 📋 planned · 🔬 research / hard · ⏳ future

---

## Horizon 1 — near-term UX (started / approved)

| # | Item | Notes |
|---|---|---|
| 1.1 | 🔜 **Reply / quote, forward, multi-select + copy** | Baseline chat UX; approved before the cleanup detour |
| 1.2 | 🔜 **Root / emulator detection** with a warning | Extends the "device compromised" model (§1.4) |
| 1.3 | 📋 Per-chat password (lock an individual conversation) | Mirrors the notes password |
| 1.4 | 📋 Edit / delete a **single** message for both sides | Control frames already exist (`MSG_DELETE`, receipts) |
| 1.5 | 📋 Local chat search (history is already encrypted at rest) | On-device only |

## Horizon 2 — foundation before a public release (**critical**)

| # | Item | Why it blocks a real release |
|---|---|---|
| 2.1 | 📋 **2–3 independent relay/mix nodes** (not one seed IP) | Today a single node is a SPOF; mixing needs ≥2 nodes to give any anonymity |
| 2.2 | 📋 **Fix CI** (GitHub Actions billing) | ~160 tests do not run automatically; every change merges unverified |
| 2.3 | 📋 **Release-signed APK** with a fixed, held signing key | Debug-signed builds can't be upgraded over and can be trivially forged |
| 2.4 | ✅ **Constant-time ML-KEM decapsulation** (audit F-1) | Done — masked compare + byte-wise select on the FO reject path |
| 2.5 | ⚠️ **Stronger password KDF** (audit F-2) | PBKDF2 raised to 600k (done); memory-hard **Argon2id** still to do |
| 2.6 | ✅ `getrandom(2)`-based RNG (audit F-3) | Done — getrandom(2) with a cached `/dev/urandom` fallback |
| 2.7 | 📋 SPQR KEM-chunking | Shrinks the ~2.3 KB per-message ratchet header (Signal's optimization) |
| 2.8 | 📋 Real BIP-39 wordlist | Replace the generated syllable list before it locks in old phrases |
| 2.9 | ⏳ **External security audit** | Listed in the protocol as a release blocker. Until then: honestly "alpha" |

## Horizon 3 — message content (biggest user-facing gap)

| # | Item | Difficulty |
|---|---|---|
| 3.1 | ✅ **Images** (downscale + encrypt + chunk across fixed 4 KB Sphinx packets) | Done — chunked transfer sub-protocol, reassembled by index |
| 3.2 | ✅ Voice messages | Done — hold-to-record, waveform, chunked over the same channel |
| 3.3 | ✅ File attachments | Done — any file, sealed at rest, opens via the OS |
| 3.4 | 📋 Typing / presence (opt-in, inside the ratchet) | Low — but a metadata trade-off, off by default |
| 3.5 | ✅ Message reactions | Done — one emoji per side, synced both ways |
| 3.6 | 📋 Reply-to / quoted messages | Low — a target id on the text frame |

**On the attachment sub-protocol (3.1–3.3).** The mixnet carries fixed-size
Sphinx payloads, so anything larger than one packet is split into chunks that
each ride in their own end-to-end-encrypted message and are reassembled by
index (duplicates and out-of-order arrival both handled). Attachment bytes are
kept **out of the app-state blob** — that blob is rewritten on every change —
and stored as individual files sealed under the state key, so nothing is ever
written in the clear. A guard test keeps the chunk size inside the onion packet
budget, since exceeding it would silently stop attachments routing.

## Horizon 4 — distribution & platforms

| # | Item | Notes |
|---|---|---|
| 4.1 | 📋 **F-Droid** | Needs a reproducible build, no proprietary blobs; depends on 2.3 |
| 4.2 | 📋 **Linux desktop** | Flutter + FRB are ready; needs a build target. Desktops make the best 24/7 nodes |
| 4.3 | 🧪 **iOS** (alpha) | Buildable now via `deploy/build-ios.sh` (macOS + Xcode). Core + UI + Face ID work; background receive is degraded and screenshots can't be blocked — see the section below |
| 4.4 | 📋 In-app APK update (no browser hop) | `REQUEST_INSTALL_PACKAGES` + FileProvider + downloader (noted in the updater) |

## Horizon 5 — network & anonymity (deepening)

| # | Item | Why |
|---|---|---|
| 5.1 | 🔬 Anonymous receive for **NAT'd phones** | SURB receive currently needs node mode + a public IP; phones poll the provider directly |
| 5.2 | 🔬 Signed node directory / eclipse-attack resistance | A malicious bootstrap can currently serve a fake "network" |
| 5.3 | 📋 Prekey / one-time-prekey rotation & replenishment | One-time prekeys should be a replenished pool, not a static bundle |
| 5.4 | 🔬 **Group messaging** (sender keys) | Sealed sender + groups is a separate protocol; deferred (§4.4) |
| 5.5 | 🔬 Multi-device | Conflicts with the "one seed = one identity" model; needs a linking design |

---

## iOS support (alpha)

iOS is now **buildable** — `deploy/build-ios.sh` (on a Mac with Xcode) cross-
compiles the Rust engine into a static library, scaffolds the `ios/` folder,
wires in the native glue, and produces a runnable app. It remains **alpha**
because a few things that are trivial on Android need a different design on iOS
and are still partial. What the build gives you today vs. what is still open:

**What ports for free**
- The **entire Rust core** (all 10 crates) compiles for `aarch64-apple-ios` and
  the simulator targets with no logic changes — it is dependency-light Rust with
  no platform assumptions beyond the RNG.
- The **Flutter UI** runs on iOS as-is; `flutter_rust_bridge` supports iOS, so
  the `AegisEngine` handle works the same way.

**Done in the alpha build**
- ✅ **RNG.** The `/dev/urandom` file read (see audit F-3 / M-001) is replaced on
  Apple platforms by a dependency-free `getentropy(3)` path in
  `aegis-crypto::rand` — no fd, kernel CSPRNG, the recommended source on iOS.
- ✅ **Face ID / Touch ID.** `local_auth` + `flutter_secure_storage` map to the
  iOS Keychain (Secure Enclave where available); the build adds the required
  `NSFaceIDUsageDescription` so the unlock flow works.
- ✅ **App-switcher privacy.** `AppDelegate` blurs the app snapshot when it
  resigns active, so the multitasking preview doesn't leak a conversation.

**Still open on iOS**
- **Background delivery.** Android's foreground `dataSync` service (24/7 receive)
  has no iOS equivalent. iOS forbids long-running background sockets; the design
  there is **push-triggered wake** — either silent push (needs a push service the
  user's provider can reach without deanonymizing them, which is a research
  problem) or `BGProcessingTask` best-effort background fetch. The build declares
  the `fetch` background mode, but expect **degraded, not continuous**, background
  receive on iOS. This is the single biggest gap.
- **Screenshot blocking.** Android `FLAG_SECURE` has **no iOS equivalent** — iOS
  can only *detect* a screenshot after the fact (`userDidTakeScreenshot`), which
  the app wires up, and blur on app-switch (done), but it **cannot prevent**
  capture while the app is open. The disguise feature (launcher `activity-alias`)
  also has no iOS analogue (no icon/alias swapping) and stays Android-only. These
  device-hardening features (§1.4) are **partial on iOS**, and the UI says so
  rather than silently dropping them.
- **Distribution.** No sideloading: iOS ships only via the **App Store** (or
  TestFlight / enterprise / AltStore-style sideload). `build-ios.sh` stops at an
  unsigned build; signing is a Xcode/Apple-ID step. App Store review of an
  anonymous E2EE messenger with disguise/duress features is a real risk and needs
  its own plan (the auto-update flow in Horizon 4.4 is Android-only and won't
  apply), as does the encryption export self-classification.

---

## Guiding constraints (unchanged)

- **Implement, don't invent.** Only published cryptographic designs; no homemade
  crypto. (The self-rolled *implementations* of those designs are exactly why the
  external audit in 2.9 is a hard release blocker.)
- **The relay stays blind.** No feature may make a node able to link sender and
  recipient.
- **Honest scope.** Ship scoped, stated guarantees (§1.1) with their limits
  (§1.3); never claim "unbreakable" or "secure" before an external audit.
