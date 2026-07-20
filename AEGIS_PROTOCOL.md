# Aegis Messaging Protocol — Design (v0 draft)

**Aegis is an anonymous, end-to-end-encrypted, post-quantum messenger built
on the Ciphra cryptographic core.** It is a Session-class messenger (no phone
numbers, no central identity authority) whose identity layer borrows Monero /
CryptoNote *stealth addressing* for recipient unlinkability, and whose
delivery layer reuses Ciphra's blind server as a store-and-forward relay.

This document is a **design**, not an implementation. It exists so the code
that follows is an implementation of a *reviewed spec*, not an invented one.

> **Guiding rule — implement, don't invent.**
> Every construction below is a well-studied, published design (X3DH / PQXDH,
> the Double Ratchet, CryptoNote stealth addresses, Sphinx, Loopix). Aegis
> writes *those* from scratch on top of Ciphra's primitives. Aegis does **not**
> design new cryptography. A homemade protocol is a broken protocol.

---

## 1. Goals and threat model

### 1.1 What Aegis must guarantee

| # | Property | Plain meaning | Delivered by |
|---|---|---|---|
| G1 | **Confidentiality** | An intercepted message cannot be read. | E2EE (§4) |
| G2 | **Forward secrecy** | Stealing today's key does not open yesterday's messages. | Double Ratchet (§4) |
| G3 | **Post-compromise security** | After a key leak, security self-heals. | Double Ratchet DH steps (§4) |
| G4 | **Post-quantum confidentiality** | "Harvest now, decrypt later" fails. | ML-KEM-768 in handshake + ratchet (§3, §4) |
| G5 | **Recipient anonymity** | The relay cannot tell who a message is *for*. | Stealth addressing (§2) |
| G6 | **Sender anonymity** | The relay cannot tell who a message is *from*. | Sealed sender (§5) |
| G7 | **Metadata / traffic-analysis resistance** | An observer cannot map who talks to whom. | Onion routing + cover traffic (§6) |
| G8 | **Authenticity** | You know who you are really talking to. | PQ-signed identity + handshake (§3) |

### 1.2 Adversaries considered

- **Passive network observer** — reads all wire traffic. Beaten by G1/G4/G7.
- **The relay operator itself** — runs an Aegis/Ciphra node. Blind by
  construction (Ciphra ADR-0003); beaten by G1/G5/G6.
- **A future quantum adversary** recording traffic today. Beaten by G4.
- **Endpoint-key theft** (one device, one moment). Bounded by G2/G3.

### 1.3 Non-goals / honest limits (v0)

- **Endpoint compromise at runtime** — if the adversary owns the device while
  Aegis is unlocked, plaintext and keys are in memory. Out of scope, same as
  Ciphra's threat model.
- **Global passive adversary defeating a busy mixnet** — Loopix (§6) raises the
  cost enormously but a truly global, long-running traffic-analysis adversary
  is the hardest open problem in the field; we claim *strong resistance*, not
  *impossibility*.
- **Anonymity-set of one** — anonymity is only as large as the crowd of Aegis
  users online. This is inherent to every anonymity system.
- **We do not use the Monero/BTC blockchain as a message bus.** Putting data
  on-chain costs a fee per message, is slow, size-limited and public. Aegis
  borrows CryptoNote's *cryptography* (stealth addresses), not its ledger. See
  §2.5.

### 1.4 Device-side hardening (coercion & shoulder-surfing)

These are client mitigations, **outside the wire protocol** — they change
nothing an observer or relay sees, so they add no metadata. They narrow the
"attacker holds the physical device" gap that §1.3 leaves open at rest.

- **At-rest encryption (everything).** Nothing is stored on disk in the clear.
  The **chat state** (contacts, history, sessions) and the **notes** are sealed
  with ChaCha20-Poly1305 under keys derived from the master seed (HKDF), so a
  file-stealer gets only ciphertext. The **seed** itself is protected two ways:
  - **With an app password** — sealed under it with PBKDF2-HMAC-SHA256 (120k
    iterations) + ChaCha20-Poly1305; the plaintext seed is deleted, the engine
    is never constructed until the password decrypts it, and bypassing the lock
    UI reaches nothing.
  - **Without a password** — held in **keystore-backed secure storage**
    (Android `EncryptedSharedPreferences`, keyed by a hardware-backed Keystore
    master key), not plaintext prefs. A stealer without the device's TEE can't
    read it, and the state/notes keys derive from it. (A legacy plaintext seed
    from older builds is migrated into the keystore on first launch.)

  So the honest gap narrows to a *fully compromised, unlocked* device with root
  (where a running process can reach the Keystore key); a password closes even
  that, since the seed is then encrypted, not merely Keystore-wrapped.
- **Duress / decoy password.** A second password seals a *separate, random*
  decoy seed. Entering it at the lock screen boots an empty but fully working
  account with its own state store; the real vault stays encrypted and is never
  touched or revealed. Nothing distinguishes the decoy from a fresh real
  account, and coercion yields only the decoy.
- **Screenshot / screen-recording block.** Android `FLAG_SECURE` is set on every
  window in `onCreate` — secure from the first frame — so there are no
  screenshots, no screen recording, and a blank card in the app switcher. On by
  default; the user can turn it off in Settings (a runtime `MethodChannel`
  toggles the flag).
- **Auto-lock & brute-force wipe.** The session re-locks after a configurable
  idle timeout and/or the instant the app is backgrounded, so an unlocked phone
  left unattended doesn't stay open (the engine is torn down and the seed
  dropped from memory until the password re-opens it). A wrong-password counter,
  persisted across restarts, **wipes everything after N failed attempts** — a
  brute-force / seized-phone defence that pairs with duress and panic wipe.
- **Panic wipe.** A hold-to-confirm control (lock screen and Settings) erases
  the seed, both vaults, all state, and node settings in one step. Fired from
  the decoy it clears only the decoy, so the real account is never destroyed —
  or disclosed — by an attacker who finds the button.
- **Local notes, encrypted at rest.** A private "Notes" self-chat that **never
  touches the network** — no send, no relay, no mailbox. It is stored in its own
  blob, sealed with ChaCha20-Poly1305 under a key derived from the master seed
  (HKDF), so a stealer that exfiltrates the app's files gets only ciphertext.
  With an app password set, the seed — and thus the notes key — is itself
  unreadable without the password. **Optional separate notes password:** a
  second encryption layer whose key is stretched from a dedicated password with
  PBKDF2-HMAC-SHA256 (~314k iterations). Reading the notes then requires **both**
  the device seed and this password — even someone who has unlocked the app
  can't open the notes without it. A **panic wipe** clears all notes (and the
  password) in one tap.
- **Launcher disguise.** The app's home-screen icon and name can be swapped
  for an ordinary utility (calculator, notes, weather) via Android
  `activity-alias` components toggled at runtime — exactly one launcher entry is
  enabled at a time. It hides *what the app is* from a casual glance at the home
  screen; it is not steganography and does not hide the installed package from
  someone who inspects the app list.
- **Biometric unlock (opt-in convenience).** Fingerprint / face can unlock in
  place of typing the password. The seed is copied into the OS keystore
  (hardware-backed where available) and released only on a live biometric match;
  wipe/reset/password-removal clears it. This is a deliberate convenience
  trade-off — it widens at-rest exposure to the keystore, and biometrics can be
  compelled, so under coercion the duress password is the answer, not this.

Runtime endpoint compromise while *unlocked* remains out of scope (§1.3); these
raise the cost of the far more common "seized/borrowed locked phone" case.

---

## 2. Layer 1 — Identity & stealth addressing (recipient anonymity, G5)

The goal: the *same* recipient must look *different* on the wire for every
message, so the relay can never link two messages as going to one person, yet
the recipient can still efficiently find messages meant for them.

This is exactly the Monero / CryptoNote **stealth address** idea. Monero uses
Ed25519 point arithmetic (`P = H(rA)·G + B`) so the one-time address is itself
a *spendable* key. A messenger does **not** need the one-time address to be a
signable key — message authenticity comes from the session keys (§3–§4), not
from the address. That lets us use a **DH-only stealth construction that needs
only X25519**, which Ciphra already ships. (Full Ed25519 CryptoNote addressing
is an optional extension — see §2.5.)

### 2.1 Identity keys

An Aegis identity is a bundle of keys, generated locally, never registered with
any authority:

| Key | Type | Ciphra primitive | Role |
|---|---|---|---|
| `IK` | ML-DSA-65 keypair | `mldsa_keypair_from_seed` | Long-term **identity signing** key (post-quantum). Signs the prekey bundle. |
| `VK = (v, V)` | X25519 keypair | `x25519::SecretKey` | **View key**: lets the owner *detect* incoming messages. `V = v·G` is published. |

`v` is the secret view scalar; `V` its public point. An **Aegis ID** shown to
users is a checksummed encoding of `(IK_pub, V)` — think of it as the Session
ID equivalent. It reveals nothing linkable on its own.

> **Why ML-DSA for identity, not Ed25519?** Ciphra already ships ML-DSA-65
> (FIPS 204), so the identity signature is post-quantum for free. ML-DSA keys
> are large (~1.9 KB pub, ~3.3 KB sig) but the identity key is published *once*,
> so size is not a hot path.

### 2.2 Stealth address per message (DH-only)

To send to recipient `R̂ = (IK_pub, V)`:

```
1. Sender draws an ephemeral X25519 keypair (r, Rpub = r·G).
2. shared   = X25519(r, V)          // = X25519(v, Rpub) for the recipient
3. secret   = HKDF-SHA256(shared, info = "aegis/addr/v1")
4. addr_tag = secret[0..16]         // 16-byte one-time address on the relay
5. view_tag = secret[16]            // 1 byte, fast-reject scan optimization
```

The message is stored on the relay under key `addr_tag`, with `Rpub` attached
in the (sealed-sender) envelope. Because `r` is fresh per message, `addr_tag`
is unlinkable across messages: the relay sees a stream of one-time tags and
sealed blobs, never a stable recipient identifier. **This satisfies G5 with
only X25519 — implementable on today's Ciphra.**

### 2.3 Recipient scanning

The recipient polls the relay for new envelopes and, for each, recomputes:

```
shared'   = X25519(v, Rpub)
secret'   = HKDF-SHA256(shared', "aegis/addr/v1")
if secret'[16] != envelope.view_tag: skip        // 1-byte reject, ~255/256 pruned
if secret'[0..16] == envelope.addr_tag: MINE      // full confirm
```

The **view tag** (borrowed from Monero's own scanning optimization) rejects
~255/256 of foreign envelopes with a single byte compare before doing the full
16-byte check — this is what keeps scanning cheap as the relay's message volume
grows.

Delegated scanning: because detection needs only `v` (not the signing key
`IK`), a user can hand a *scanning-only* copy of `v` to a helper (e.g. a
push-notification service) that can find their envelopes but cannot read them
(reading needs the session keys) and cannot impersonate them.

### 2.4 Anti-spam / anti-Sybil (optional, this is where a chain *may* help)

Stealth addressing means anyone can write to anyone — good for openness, but
open to flooding. Options, in increasing cost:

- **Hashcash / proof-of-work** stamp per message (self-contained, no chain).
- **Sender-pays**: a tiny Monero payment or burn proof attached to first
  contact. This is the *only* place a blockchain earns its keep in Aegis, and
  it is optional. Not a message bus — an anti-Sybil toll.

### 2.5 Optional extension — full CryptoNote (Ed25519) addressing

If Aegis later wants one-time addresses that are *also signable keys* (e.g. to
bind messaging identity to a Monero wallet for integrated payments), that needs
Ed25519 group operations (point addition, scalar-basepoint mult) which Ciphra
does **not** currently expose — it has X25519 (Montgomery ladder, DH only) and
ML-DSA (lattice). That would mean implementing Ed25519 / Ristretto255 from
RFC 8032 in `ciphra-crypto`. **Scoped as a future extension, not needed for
G1–G8.** The DH-only construction in §2.2 delivers recipient anonymity today.

---

## 3. Layer 2 — Session handshake: PQXDH (G4, G8)

To start a conversation, the initiator needs a shared secret with a recipient
who may be **offline**. This is asynchronous key agreement — Signal's X3DH,
upgraded to its post-quantum form **PQXDH**. Aegis reuses the exact primitive
mix Ciphra already assembles for its transport (`hybrid.rs`: X25519 +
ML-KEM-768).

### 3.1 Prekey bundle (published once, refreshed periodically)

Each user uploads to the relay a bundle, **all fields signed by `IK`**:

| Field | Type | Ciphra primitive |
|---|---|---|
| `IK_pub` | ML-DSA-65 public key | `mldsa_*` |
| `SPK` | X25519 signed prekey (medium-term) | `x25519` |
| `PQSPK` | ML-KEM-768 signed prekey | `ml_kem` (EK_LEN 1184) |
| `OPK[]` | X25519 one-time prekeys (pool, each used once) | `x25519` |
| `V` | X25519 view key (§2) | `x25519` |
| `sig` | ML-DSA-65 signature over all of the above | `mldsa_sign` |

Signing the whole bundle with the PQ identity key gives G8: an initiator
verifies `sig` against `IK_pub` and knows the prekeys are authentic.

### 3.2 Initiator computes the shared secret

Let initiator identity DH key be `IK^x_A` (an X25519 key bound to the identity;
distinct from the ML-DSA signing key). Initiator draws an ephemeral `EK_A`.

```
DH1 = X25519(IK^x_A, SPK_B)
DH2 = X25519(EK_A,  IK^x_B)
DH3 = X25519(EK_A,  SPK_B)
DH4 = X25519(EK_A,  OPK_B)          // omitted if the OPK pool is empty
(CT, SS_pq) = ML-KEM-768.encapsulate(PQSPK_B)     // ciphra ml_kem::encapsulate

SK = HKDF-SHA256(
        salt = 0,
        ikm  = DH1 ‖ DH2 ‖ DH3 ‖ DH4 ‖ SS_pq,
        info = "aegis/pqxdh/v1")
```

`SK` seeds the Double Ratchet (§4). The initial message carries `IK^x_A`,
`EK_A`, the KEM ciphertext `CT`, and which `SPK`/`OPK` were used — all inside
the sealed-sender envelope (§5).

### 3.3 Why the mix

- `DH1..DH4` (classical X25519) authenticate both parties and give mutual key
  agreement — the X3DH property.
- `SS_pq` (ML-KEM-768) injects post-quantum secrecy: recording `CT` today and
  breaking X25519 later still leaves `SS_pq` sealed → **G4**.
- Mixing all secrets through HKDF means the session holds if *any one*
  primitive survives. This is exactly Ciphra's transport rationale
  (ARCHITECTURE §"Transport security"), applied to end-to-end sessions.

---

## 4. Layer 3 — Conversation encryption: PQ Double Ratchet (G1, G2, G3, G4)

Once `SK` is established, every message is encrypted with the **Double
Ratchet** (Signal). Two ratchets combine:

- **Symmetric-key ratchet** — a KDF chain advances one step per message, so
  **every message gets a unique key** and old keys are discarded (**G2**).
- **DH ratchet** — parties attach a fresh X25519 public key to messages;
  each new DH injects fresh entropy, so a key compromise heals after one
  round trip (**G3**).

### 4.1 Primitive mapping (all in `ciphra-crypto`)

| Ratchet element | Construction | Ciphra call |
|---|---|---|
| Root KDF | `HKDF-SHA256(root_key, dh_out)` → new root + chain key | `hkdf_extract`/`hkdf_expand` |
| Chain KDF | `HMAC-SHA256(chain_key, const)` → msg key, next chain key | `hmac_sha256` |
| Message AEAD | ChaCha20-Poly1305, key = message key | `CipherKey::seal`/`open` |
| DH step | X25519 | `x25519::SecretKey::diffie_hellman` |
| AAD | header (ratchet pub, counters) bound into the seal | `seal(pt, aad)` |

Ciphra's `CipherKey::seal(plaintext, aad)` is a perfect fit: the ratchet header
(sender ratchet key, message number, previous-chain length) goes in as `aad`,
binding each ciphertext to its position so reordering/replay fails to open —
mirroring how Ciphra binds a row ciphertext to its storage key.

### 4.2 Post-quantum ratchet (G4 over the whole conversation)

X3DH/PQXDH makes the *initial* secret post-quantum, but a pure X25519 DH
ratchet would leak PQ security over a long-lived conversation. Following
Signal's PQ ratchet direction (PQ3 / "SPQR"), Aegis periodically performs an
**ML-KEM-768 re-encapsulation** alongside the DH ratchet: every *N* DH steps
(or *T* time), one party encapsulates to the other's rotating ML-KEM public key
and the resulting shared secret is mixed into the root KDF. This keeps the
whole conversation — not just its first message — quantum-resistant, at the
cost of periodically shipping a ~1 KB KEM ciphertext.

### 4.3 Application framing & delivery receipts (G1 preserved)

Inside the ratchet plaintext, every payload carries a 1-byte **kind** and an
8-byte **message id**: `Text`, `Delivered`, or `Read`. A text message is shown
and, on receipt, the recipient auto-replies with a `Delivered` receipt over the
same session; opening the chat sends a `Read` receipt. Receipts reference the
original id, carry no content, and never trigger further receipts. Because they
ride inside the Double Ratchet like any message, the relay and mixnet see only
sealed envelopes — read state leaks nothing to the network, only to the two
endpoints. The sender's UI shows `✓` sent · `✓✓` delivered · bright `✓✓` read.

### 4.4 Group messaging (later)

v0 targets 1:1. Groups use **sender keys** (each member ratchets their own
chain, distributes the chain key pairwise via the 1:1 channel) — same primitives,
deferred past the 1:1 milestone.

---

## 5. Layer 4a — Delivery: blind store-and-forward + sealed sender (G6)

The relay is **Ciphra's blind server, unchanged** — it stores sealed bytes and
holds no keys (ADR-0003). Aegis models a message as a row:

```
key   = addr_tag           (16-byte one-time stealth tag from §2.2)
value = sealed envelope     (opaque to the relay)
```

Envelope layout (all but the routing header is opaque to the relay):

```
envelope := Rpub ‖ ratchet_header ‖ ciphertext
ciphertext := DoubleRatchet.seal( inner )
inner := sender_identity ‖ pqxdh_or_ratchet_payload ‖ message
```

### 5.1 Sealed sender (G6)

The sender's identity (`inner.sender_identity`) is **inside** the E2EE
ciphertext — only the recipient, after deriving the message key, learns who
sent it. The relay sees `addr_tag`, `Rpub`, and a sealed blob: **not who it is
from, not who it is to** (G5 + G6 together). This is Signal's "sealed sender"
made stronger, because even the *recipient* tag is one-time.

### 5.2 Mailbox mechanics on Ciphra

- **Send** = `INSERT` a row keyed by `addr_tag` into the relay's Ciphra store.
- **Fetch** = the recipient pulls new rows since a cursor and trial-scans them
  (§2.3). Because scanning is client-side, the relay never learns which rows
  matched — recipient-relay unlinkability holds even against the relay.
- **Replication** = Ciphra log-shipping already fans messages across a *swarm*
  of relays for availability; each replica is as blind as the leader.
- **Expiry / disappearing messages** = TTL on rows; the relay drops expired
  sealed blobs it cannot read anyway.

> This is the payoff of building on Ciphra: the entire "store-and-forward,
> multi-node, blind, replicated mailbox" layer is **already implemented**. Aegis
> adds an addressing convention (§2) and an envelope format (§5) on top.

---

## 6. Layer 4b — Network anonymity: onion routing → mixnet (G7)

Everything above hides *content* and *identity tags*. It does **not** by itself
hide that IP `X` uploaded an envelope and IP `Y` fetched around the same time —
that is traffic analysis. This is the one genuinely hard layer, and the one
piece not already in Ciphra. Recommended path, in phases:

### 6.1 Phase A — Onion routing (Sphinx)

Route each envelope through 3 relays using the **Sphinx** packet format: each
hop peels one layer (its own X25519 + a per-hop symmetric key), learning only
the next hop, never the origin or the payload. Fixed-size packets prevent
length correlation. This is the Session/Lokinet model and is self-implementable
from Ciphra's X25519 + ChaCha20 + HKDF (Sphinx needs no new primitives).

Gives: no single relay knows both sender and recipient. Beaten only by an
adversary watching *both* ends and correlating timing.

### 6.2 Phase B — Mix layer (Loopix)

Upgrade the relays from routers to **mixes** (Loopix design):

- **Poisson mixing** — each mix independently delays packets by an
  exponential random time, destroying input↔output timing correlation.
- **Cover traffic** — clients and mixes emit indistinguishable dummy packets on
  a Poisson schedule, so "sent a message" is invisible against a constant
  background. This is what raises the bar against a *global* observer.

Loopix is the current academic state of the art for practical, low-latency
metadata protection and is implementable from the same primitives.

### 6.3 Honest cost

Cover traffic and mixing trade **bandwidth and latency** for anonymity. Aegis
should make this a **tunable**: a "fast" mode (onion only, low latency) and a
"paranoid" mode (full Loopix cover traffic). Do not oversell — see §1.3.

### 6.4 Transport proxy (SOCKS5 / Tor) — hiding the client IP

The mixnet hides *who talks to whom*, but the **first hop still sees the
client's IP** (a node learns that IP `X` connected to it). As a client-side
option, Aegis can route **every** outbound TCP — both the mixnet dials and the
provider/mailbox connection — through a **SOCKS5 proxy**. Tor is exactly a
SOCKS5 proxy (Orbot on `127.0.0.1:9050`), so the same mechanism gives "use Tor"
and "use my SOCKS5 proxy". With it on, the entry node sees the proxy/Tor exit,
not the user's address. This composes with — and does not replace — the mixnet:
it protects the *network address*, the mixnet protects the *traffic pattern*.
Combined with **own-nodes-only** routing, a user can insist all traffic goes
through infrastructure they control, reached over Tor. (Node/provider targets
are IPs, so no separate DNS resolution leaks; a hostname relay would still
resolve locally.)

The proxy is an **ordered chain** of SOCKS5 hops
(`app → hop₁ → hop₂ → … → target`): each hop is reached by a SOCKS5 CONNECT
through the previous one, with a DOMAINNAME CONNECT for hostname hops so
intermediate resolution happens at the proxy, not locally. A common two-hop
setup is **app → SOCKS5 → Tor** (or **Tor → SOCKS5**); when Tor is a local
Orbot, put Tor first, since a remote SOCKS5 can't reach the phone's loopback
Tor. Chaining lets a user stack their own proxy with Tor rather than trusting
either alone.

---

## 7. End-to-end message lifecycle

```
SENDER                              RELAY SWARM (Ciphra, blind)         RECIPIENT
------                              ---------------------------         ---------
know recipient Aegis ID (IK,V)
 │
 ├─ PQXDH: fetch signed prekey bundle, verify with IK  ────────────────▶ (bundle)
 ├─ derive SK (X25519×4 ‖ ML-KEM SS)          §3
 ├─ init Double Ratchet from SK               §4
 ├─ stealth: r, Rpub, addr_tag, view_tag      §2.2
 ├─ seal inner (sender id + payload + msg)    §4/§5
 ├─ wrap Sphinx onion (3 hops)                §6
 └─ inject ──▶ mix ──▶ mix ──▶ mix ──▶ INSERT row[addr_tag] = envelope
                                              (relay sees: one-time tag +
                                               sealed blob. Not from/to whom.)
                                                                          │
                                          poll new rows ◀─────────────────┤
                              trial-scan with v (view_tag fast-reject) §2.3
                                          match addr_tag ────────────────▶ MINE
                              X25519(v,Rpub) → session → ratchet.open() ─▶ plaintext
```

---

## 8. Mapping to Ciphra crates — what exists vs. what Aegis adds

| Aegis need | Status | Where |
|---|---|---|
| ChaCha20-Poly1305 AEAD | ✅ exists | `ciphra-crypto` `CipherKey::seal/open` |
| X25519 DH | ✅ exists | `x25519::SecretKey` |
| ML-KEM-768 (PQ KEM) | ✅ exists | `ml_kem::{generate,encapsulate,decapsulate}` |
| ML-DSA-65 (PQ sign) | ✅ exists | `mldsa_{keypair_from_seed,sign,verify}` |
| HKDF / HMAC / SHA-256 / SHA-3 / BLAKE2b | ✅ exists | `ciphra-crypto` |
| Hybrid X25519+ML-KEM handshake | ✅ exists (transport) | `hybrid.rs` — adapt to PQXDH |
| Blind store-and-forward relay | ✅ exists | `ciphra-server` |
| Multi-node replication (swarm) | ✅ exists | Ciphra log shipping |
| Deterministic keyed tags | ✅ exists | `MasterKey::keyed_tag` |
| **Stealth addressing (DH-only)** | ✅ done | `aegis-identity` |
| **PQXDH session setup** | ✅ done | `aegis-session` |
| **PQ Double Ratchet (ongoing ML-KEM)** | ✅ done | `aegis-session` |
| **ML-DSA-signed prekey bundles (G8)** | ✅ done | `aegis-session` + `aegis-identity` |
| **Sealed-sender envelope + mailbox** | ✅ done | `aegis-mailbox` |
| **Sphinx onion routing (LIONESS payload)** | ✅ done | `aegis-net` |
| **Loopix mixing + cover traffic** | ✅ done | `aegis-net` |
| **Live Ciphra blind-server relay** | ✅ done | `aegis-relay` (Ciphra `RemoteStorage`) |
| **One-identity client API** | ✅ done | `aegis-client` |
| Ed25519 / CryptoNote signable one-time keys | ⏳ optional/future | would extend `ciphra-crypto` (§2.5) |

**Read of the table:** every *primitive* Aegis needs already existed in Ciphra
and is test-vector-verified; the Aegis crates re-implement the small subset not
publicly exported. Aegis is protocol-assembly work, not cryptographic-primitive
work — except the network-anonymity layer (§6), which is new but needs no new
primitives. **All rows above are implemented and tested.**

---

## 9. Crate layout (as built)

```
aegis/
├── crates/
│   ├── aegis-crypto/     # zero-dep primitives (x25519, ml_kem, ml_dsa, aead, …)
│   ├── aegis-identity/   # Aegis ID, keypairs, signing, stealth addressing (§2)
│   ├── aegis-session/    # PQXDH handshake (§3) + ongoing-PQ Double Ratchet (§4)
│   ├── aegis-mailbox/    # sealed-sender envelope + blind MailboxStore (§5)
│   ├── aegis-net/        # Sphinx onion routing (LIONESS) + Loopix mixing (§6)
│   ├── aegis-relay/      # CiphraStore: MailboxStore over a live Ciphra server
│   └── aegis-client/     # AegisClient — one identity, one API over all layers
├── AEGIS_PROTOCOL.md     # this document
└── docs/CRYPTO_MATH.md   # the exact mathematics
```

`aegis-relay` depends on Ciphra's `ciphra-net` (`RemoteStorage`) to reach a live
blind server; everything else is self-contained zero-dependency Rust.

---

## 10. Phased roadmap — status

- **Phase 0 — identity.** ✅ `aegis-identity`: keygen, Aegis ID encoding, DH-only
  stealth address derive + scan with view tags (§2), ML-DSA signing.
- **Phase 1 — sessions.** ✅ `aegis-session`: PQXDH from signed prekey bundles
  (§3) + ongoing-PQ Double Ratchet (§4). Delivers G1–G4, G8.
- **Phase 2 — delivery.** ✅ `aegis-mailbox` (sealed-sender envelopes, blind
  `MailboxStore`) + `aegis-relay` (`CiphraStore` over a **live Ciphra blind
  server**, tested end-to-end). Delivers G5, G6.
- **Phase 3 — network anonymity.** ✅ `aegis-net`: Sphinx onion routing with a
  non-malleable LIONESS payload (§6.1), and Loopix Poisson mixing + cover
  traffic (§6.2). Delivers G7.
- **Integration.** ✅ `aegis-client`: one identity, one messenger API over all
  layers.
- **Remaining hardening.** ⏳ SPQR KEM-chunking to shrink the ratchet header
  (§4.2), groups (§4.3), anti-Sybil toll (§2.4), and an external security audit
  (blocker for any "secure" claim — same stance as Ciphra).

Each phase is independently tested and leaves Aegis in a working state.

---

## 11. What we deliberately are **not** doing

- ❌ **Inventing new crypto.** Only implementing published designs.
- ❌ **Using the blockchain to carry messages.** Fees, latency, size, public
  permanence. The chain is (optionally) an anti-Sybil toll, never the bus.
- ❌ **Trusting the relay.** It is blind by construction; anonymity does not
  depend on relay honesty.
- ❌ **Claiming "unbreakable".** We claim specific, scoped properties (§1.1) and
  state the limits (§1.3). An unaudited system makes no security promises.

---

*Status: v0. This document was written as the design contract first; **all five
layers are now implemented and tested** against it (see the crate map and the
per-crate test counts in the [README](README.md)). What remains is hardening and
an external security audit, not new protocol layers.*
