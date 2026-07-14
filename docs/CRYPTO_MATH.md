# Aegis — Exact Cryptographic Mathematics

Companion to [`AEGIS_PROTOCOL.md`](../AEGIS_PROTOCOL.md). This document states
the **precise** mathematics of every process: the group, the scalar/point
operations, the KDF inputs byte-for-byte, correctness proofs, and the security
assumption each step rests on. It is the reference the implementation is checked
against.

Everything is expressed in terms of primitives Ciphra already ships:
`x25519`, `ml_kem`, `ml_dsa`, `hkdf_extract`/`hkdf_expand`, `hmac_sha256`,
`sha256`, `blake2b`, ChaCha20-Poly1305 (`CipherKey`).

---

## 0. Notation and the underlying group

### 0.1 Curve25519

All Diffie–Hellman and onion routing happen in the group of Curve25519, the
Montgomery curve

$$
E : v^2 = u^3 + 486662\,u^2 + u \pmod{p}, \qquad p = 2^{255} - 19 .
$$

- The base point has $u = 9$; call it $B$ (a point) or, in exponent notation,
  $g$. Its prime order is
  $$
  \ell = 2^{252} + 27742317777372353535851937790883648493 ,
  $$
  and the curve cofactor is $8$ (full order $8\ell$).
- A **scalar** is an integer $n$; a **point** is a $u$-coordinate (32 bytes).
- `X25519(n, P)` computes the $u$-coordinate of $n\cdot P$ via the Montgomery
  ladder. In multiplicative ("exponent") notation we write $P^{n}$.
- **Clamping.** X25519 clamps every scalar $n$: clear bits 0,1,2 and bit 255,
  set bit 254. This forces $n$ into a fixed coset (a multiple of the cofactor,
  in $[2^{254}, 2^{255})$), killing small-subgroup attacks. Write $\bar n$ for
  the clamped scalar. Two facts we rely on:
  1. **Commutativity survives clamping:** $\;(P^{\bar a})^{\bar b} = P^{\bar a\bar b} = (P^{\bar b})^{\bar a}$, because scalar multiplication commutes and clamping just fixes the concrete integers. So DH still works: `X25519(a, X25519(b,B)) = X25519(b, X25519(a,B))`.
  2. **Consistency under composition:** if sender and receiver apply the *same*
     `X25519(·, ·)` calls with the *same* byte-scalars, they get identical
     points regardless of clamping. This is what makes Sphinx (§5) work over
     X25519.

### 0.2 Symbols

| Symbol | Meaning |
|---|---|
| $B$, $g$ | Curve25519 base point ($u=9$) |
| $P^{n}$ / `X25519(n,P)` | scalar mult, $u$-coordinate of $n\cdot P$ |
| $x \mathbin\| y$ | byte concatenation |
| $H(m)$ | SHA-256 |
| $\mathrm{HKDF}(\text{salt},\text{ikm},\text{info},L)$ | HKDF-SHA256 → $L$ bytes (`hkdf_extract` then `hkdf_expand`) |
| $\mathrm{MAC}_k(m)$ | `hmac_sha256(k, m)` |
| $H_s(m)$ | hash-to-scalar: $\mathrm{HKDF}(\varnothing,m,\text{"…/scalar"},64)\bmod \ell$ |
| $\mathrm{AEAD}_k(n,ad,pt)$ | ChaCha20-Poly1305 seal, key $k$, nonce $n$, assoc. data $ad$ |
| $0^{t}$ | $t$ zero bytes |

**Hash-to-scalar** reduces a 64-byte HKDF output modulo $\ell$ (wide reduction:
64 bytes ≫ 253 bits, so the bias is $< 2^{-128}$ and negligible).

---

## 1. Stealth addressing (recipient anonymity)

### 1.1 Keys

Recipient view keypair: secret scalar $v$, public point $V = B^{v}$
(`X25519(v, 9)`). $v$ is X25519-clamped, so really $V = B^{\bar v}$; we drop the
bar below.

### 1.2 Sender derives a one-time address

For each message the sender draws a fresh ephemeral scalar $r$ and computes:

$$
\begin{aligned}
R &= B^{r} && \text{(ephemeral public point, sent with the message)}\\
S &= V^{r} = B^{vr} && \text{shared secret point} = \texttt{X25519}(r, V)\\
\sigma &= \mathrm{HKDF}\!\big(\varnothing,\; S,\; \texttt{"aegis/addr/v1"} \mathbin\| R \mathbin\| V,\; 17\big)\\
\textbf{addr\_tag} &= \sigma[0..16] && \text{16-byte relay storage key}\\
\textbf{view\_tag} &= \sigma[16] && \text{1-byte fast-reject}
\end{aligned}
$$

The message is stored on the relay at key `addr_tag`, with $R$ inside the
envelope (§4 of the protocol doc). $R$ and $V$ are folded into the HKDF `info`
so the tag is bound to this exact ephemeral and this exact recipient.

### 1.3 Recipient recovers the address

The recipient, holding $v$, recomputes for each incoming $R$:

$$
S' = R^{v} = B^{rv} = \texttt{X25519}(v, R).
$$

**Correctness.** $S' = B^{rv} = B^{vr} = S$ by commutativity (§0.1), so
$\sigma' = \sigma$, hence `view_tag`/`addr_tag` match iff the message is theirs.

Scan procedure (cheap):

```
S'      = X25519(v, R)
σ'      = HKDF(∅, S', "aegis/addr/v1" ‖ R ‖ V, 17)
if σ'[16] ≠ view_tag:   skip          # rejects ~255/256 of foreign msgs
if σ'[0..16] = addr_tag: MINE
```

### 1.4 Unlinkability (why the relay learns nothing)

Two messages to the same recipient produce tags $\sigma_1$ (from $r_1$) and
$\sigma_2$ (from $r_2$). Distinguishing "same recipient" from "different
recipients" requires distinguishing $\big(B^{r_1}, B^{r_2}, \mathrm{HKDF}(B^{vr_1}), \mathrm{HKDF}(B^{vr_2})\big)$ from tags with independent secrets — a
**Decisional Diffie–Hellman (DDH)** distinguisher on Curve25519, composed with
HKDF modelled as a random oracle. Under DDH the tags are pseudorandom and
unlinkable. The relay sees only $\{(R_i, \text{addr\_tag}_i, \text{blob}_i)\}$,
each $R_i$ a uniform point, each tag a uniform 16 bytes.

### 1.5 Contributory-behaviour / zero check

If a malicious counterpart supplies a small-order $V$ or $R$, `X25519` can
output the all-zero point. Per RFC 7748 §6.1 we **reject an all-zero shared
secret** ($S = 0^{32}$) before deriving tags. Clamping already removes the
cofactor, so honest keys never trigger this.

---

## 2. PQXDH — asynchronous post-quantum handshake

### 2.1 Long-term keys

Each user $U$ holds:

- $\mathrm{IK}^{\text{sig}}_U$ — ML-DSA-65 keypair (identity signing).
- $\mathrm{IK}^{\text{dh}}_U = (ik_U,\; \mathrm{IK}_U = B^{ik_U})$ — X25519 identity DH key.
- view key $(v_U, V_U)$ from §1.

The **Aegis ID** commits to the triple
$\big(\mathrm{IK}^{\text{sig}}_U,\ \mathrm{IK}_U,\ V_U\big)$ (checksummed
encoding), so all three are bound to one identity.

### 2.2 Prekey bundle (published, signed once)

Recipient $B$ publishes and signs with $\mathrm{IK}^{\text{sig}}_B$:

$$
\text{bundle}_B = \Big(\ \mathrm{IK}_B,\ \mathrm{SPK}_B = B^{spk_B},\ \mathrm{PQSPK}_B \in \{0,1\}^{1184},\ \{\mathrm{OPK}^{(j)}_B\},\ V_B\ \Big),
$$
$$
\text{sig} = \texttt{mldsa\_sign}\big(\mathrm{IK}^{\text{sig}}_B,\ H(\text{bundle}_B)\big).
$$

$\mathrm{PQSPK}_B$ is an **ML-KEM-768 encapsulation key** (`ek`, 1184 bytes).
The initiator verifies `sig` first (`mldsa_verify`) — this is authenticity
(G8).

### 2.3 Initiator $A$ computes the session secret

$A$ draws an ephemeral X25519 key $\mathrm{EK}_A = B^{ek_A}$ and computes four
DHs plus one KEM:

$$
\begin{aligned}
\mathrm{DH}_1 &= \mathrm{SPK}_B^{\,ik_A} = \texttt{X25519}(ik_A, \mathrm{SPK}_B) & &\text{(A-identity ↔ B-prekey)}\\
\mathrm{DH}_2 &= \mathrm{IK}_B^{\,ek_A} = \texttt{X25519}(ek_A, \mathrm{IK}_B) & &\text{(A-ephemeral ↔ B-identity)}\\
\mathrm{DH}_3 &= \mathrm{SPK}_B^{\,ek_A} = \texttt{X25519}(ek_A, \mathrm{SPK}_B) & &\text{(A-ephemeral ↔ B-prekey)}\\
\mathrm{DH}_4 &= \mathrm{OPK}_B^{\,ek_A} = \texttt{X25519}(ek_A, \mathrm{OPK}_B) & &\text{(optional one-time)}\\
(\mathrm{CT},\ \mathrm{SS}) &= \texttt{ml\_kem.encapsulate}(\mathrm{PQSPK}_B) & &\text{(FIPS 203, }\mathrm{SS}\in\{0,1\}^{32})
\end{aligned}
$$

Key derivation, with the X3DH domain-separation prefix $F = \texttt{0xFF}^{32}$:

$$
\begin{aligned}
\mathrm{IKM} &= F \mathbin\| \mathrm{DH}_1 \mathbin\| \mathrm{DH}_2 \mathbin\| \mathrm{DH}_3 \mathbin\| \mathrm{DH}_4 \mathbin\| \mathrm{SS} \\
\mathrm{SK}  &= \mathrm{HKDF}\big(\text{salt}=0^{32},\ \mathrm{IKM},\ \texttt{"aegis/pqxdh/v1"},\ 32\big).
\end{aligned}
$$

(If no one-time prekey is available, $\mathrm{DH}_4$ is omitted from $\mathrm{IKM}$;
the string `"aegis/pqxdh/v1-noopk"` is used instead so the two cases can never
collide.)

The first message carries $\big(\mathrm{IK}_A,\ \mathrm{EK}_A,\ \mathrm{CT},\
\text{prekey-ids}\big)$ and is bound with associated data
$\mathrm{AD} = \mathrm{IK}_A \mathbin\| \mathrm{IK}_B$.

### 2.4 Responder $B$ reconstructs $\mathrm{SK}$

$B$ has $ik_B, spk_B, opk_B$ and the ML-KEM decapsulation key $dk_B$:

$$
\begin{aligned}
\mathrm{DH}_1 &= \mathrm{IK}_A^{\,spk_B}, &
\mathrm{DH}_2 &= \mathrm{EK}_A^{\,ik_B}, &
\mathrm{DH}_3 &= \mathrm{EK}_A^{\,spk_B}, &
\mathrm{DH}_4 &= \mathrm{EK}_A^{\,opk_B},\\
\mathrm{SS} &= \texttt{ml\_kem.decapsulate}(dk_B,\ \mathrm{CT}).
\end{aligned}
$$

**Correctness.** Each $\mathrm{DH}_i$ matches by commutativity, e.g.
$\mathrm{SPK}_B^{ik_A} = B^{spk_B\, ik_A} = B^{ik_A\, spk_B} = \mathrm{IK}_A^{spk_B}$;
and ML-KEM decapsulation returns the same $\mathrm{SS}$ that was encapsulated
(FIPS 203 correctness, with implicit-rejection making a bad $\mathrm{CT}$ yield a
pseudorandom-but-consistent value). Hence both sides derive identical
$\mathrm{SK}$.

### 2.5 Security

- **Classical:** breaking $\mathrm{SK}$ needs all of $\mathrm{DH}_1..\mathrm{DH}_4$
  → Gap-DH / CDH on Curve25519. Mutual authentication comes from $\mathrm{DH}_1$
  (binds $A$'s identity) and $\mathrm{DH}_2$ (binds $B$'s identity).
- **Post-quantum (G4):** even if a quantum adversary later breaks every
  $\mathrm{DH}_i$, the term $\mathrm{SS}$ stays hidden under **ML-KEM-768
  IND-CCA2** (Module-LWE). Since $\mathrm{SK}=\mathrm{HKDF}(\dots\|\mathrm{SS})$
  and HKDF is a dual-PRF, one surviving high-entropy input keeps $\mathrm{SK}$
  pseudorandom. Recording $\mathrm{CT}$ today does not help tomorrow →
  harvest-now-decrypt-later defeated.

---

## 3. The Double Ratchet

Session output $\mathrm{SK}$ (§2) seeds the ratchet. State per party:
root key $\mathrm{RK}$, sending/receiving chain keys $\mathrm{CK}_s,\mathrm{CK}_r$,
own ratchet keypair $(\mathrm{rk},\ \mathrm{RK}_{\text{pub}}=B^{rk})$, the peer's
current ratchet public $\mathrm{RK}^{\text{peer}}_{\text{pub}}$, message counters
$N_s, N_r$, previous-chain length $\mathrm{PN}$, and a store of skipped message
keys.

### 3.1 The two KDFs

**Root KDF** (advances on every DH ratchet step). Input: current $\mathrm{RK}$
and a DH output $d$:

$$
\mathrm{KDF_{RK}}(\mathrm{RK}, d) = \mathrm{HKDF}\big(\text{salt}=\mathrm{RK},\ \text{ikm}=d,\ \texttt{"aegis/ratchet/root"},\ 64\big),
$$

split as $\mathrm{RK}' = \text{out}[0..32]$, $\mathrm{CK} = \text{out}[32..64]$.
Using $\mathrm{RK}$ as the HKDF **salt** is the standard construction (HKDF is a
secure dual-PRF, so mixing a secret salt with secret ikm is sound).

**Chain KDF** (advances on every message). Symmetric-key ratchet:

$$
\mathrm{mk} = \mathrm{MAC}_{\mathrm{CK}}(\texttt{0x01}), \qquad
\mathrm{CK}' = \mathrm{MAC}_{\mathrm{CK}}(\texttt{0x02}).
$$

Distinct constants give two independent PRF outputs from the chain key: `mk`
is spent on one message, `CK'` replaces `CK`. Old `CK` is zeroized → **forward
secrecy (G2)**: `mk` cannot be rolled back to earlier keys because HMAC is
one-way.

**Message key expansion** to ChaCha20-Poly1305 material:

$$
\mathrm{HKDF}(\varnothing,\ \mathrm{mk},\ \texttt{"aegis/ratchet/msg"},\ 44)
\;\to\; (\underbrace{k}_{32},\ \underbrace{n}_{12}).
$$

Encryption of plaintext $m$ with header $h$ (§3.3) as associated data:

$$
c = \mathrm{AEAD}_{k}\big(n,\ ad=h,\ pt=m\big) = \texttt{CipherKey(k).seal}(m,\ h).
$$

### 3.2 DH ratchet step

When a message arrives carrying a **new** peer ratchet public
$\mathrm{RK}^{\text{peer'}}_{\text{pub}}$:

```
PN            = N_s ; N_s = 0 ; N_r = 0
d_recv        = X25519(rk, RK_peer'_pub)                 # DH with our current key
RK, CK_r      = KDF_RK(RK, d_recv)                       # new receiving chain
(rk, RK_pub)  = generate new X25519 keypair
d_send        = X25519(rk, RK_peer'_pub)                 # DH with our NEW key
RK, CK_s      = KDF_RK(RK, d_send)                       # new sending chain
```

**Post-compromise security (G3):** each step folds a *fresh* ephemeral DH into
$\mathrm{RK}$ via $\mathrm{KDF_{RK}}$. Once both sides have rotated after a leak,
$\mathrm{RK}$ contains entropy the attacker never saw, so security self-heals
after one round trip. The DH outputs $d$ rest on CDH.

### 3.3 Message header and sending

$$
h = \big(\ \mathrm{RK}_{\text{pub}}\ \mathbin\|\ \mathrm{PN}\ \mathbin\|\ N_s\ \big).
$$

```
mk       = MAC_{CK_s}(0x01) ; CK_s = MAC_{CK_s}(0x02)
(k, n)   = HKDF(∅, mk, "aegis/ratchet/msg", 44)
ct       = AEAD_k(n, ad = h, pt = m)
send (h, ct) ; N_s += 1
```

### 3.4 Receiving and out-of-order messages

On $(h, ct)$ with $h = (\mathrm{RK}^{\text{peer}}_{\text{pub}}, \mathrm{PN}, N)$:

1. If $\mathrm{RK}^{\text{peer}}_{\text{pub}}$ is new: first **skip** the tail of
   the *old* receiving chain up to $\mathrm{PN}$ (store those `mk`s), then run the
   DH ratchet step (§3.2).
2. **Skip** forward in the current receiving chain from $N_r$ to $N$, storing
   each intermediate `mk` in `MK_SKIPPED[RK_peer_pub, i]`. Enforce
   `MAX_SKIP` (e.g. 1000) to bound work — reject beyond it.
3. Derive `mk` for index $N$ (either from the skipped store, or by advancing
   `CK_r`), expand, and `open`. `N_r = N + 1`.

Skipped-key storage is what lets messages arrive out of order or be dropped
without breaking the chain; keys are deleted once used (or on TTL).

---

## 4. Post-quantum ratchet (KEM re-encapsulation)

A pure X25519 DH ratchet is not post-quantum for the *ongoing* conversation.
Following Signal's SPQR, Aegis mixes an ML-KEM shared secret into the root KDF
periodically.

### 4.1 Augmented ratchet keys

Every ratchet-key advertisement also carries a fresh **ML-KEM-768 encapsulation
key** $\mathrm{ek}^{\text{kem}}$. When a party does the DH ratchet step (§3.2)
and the epoch counter hits the cadence $T$ (e.g. every ratchet step, or every
$T$ messages), it also encapsulates to the peer's advertised KEM key:

$$
(\mathrm{CT}^{\text{kem}},\ \mathrm{SS}^{\text{kem}}) = \texttt{ml\_kem.encapsulate}\big(\mathrm{ek}^{\text{kem}}_{\text{peer}}\big),
$$

and the root step mixes both secrets:

$$
d^{+} = \texttt{X25519}(rk,\ \mathrm{RK}^{\text{peer}}_{\text{pub}})\ \mathbin\|\ \mathrm{SS}^{\text{kem}},
\qquad
\mathrm{RK}, \mathrm{CK} = \mathrm{KDF_{RK}}(\mathrm{RK},\ d^{+}).
$$

$\mathrm{CT}^{\text{kem}}$ (≈1088 bytes) travels in the header of that epoch's
first message; the peer decapsulates with its KEM secret to recover
$\mathrm{SS}^{\text{kem}}$.

### 4.2 Property

After each KEM mix, $\mathrm{RK}$ depends on a Module-LWE secret. A quantum
adversary that breaks the X25519 half still faces IND-CCA2 ML-KEM on the other
half of $d^{+}$; by the dual-PRF property of HKDF, $\mathrm{RK}$ stays
pseudorandom. So **the whole conversation**, not just its first message, is
post-quantum confidential. Cost: one ~1 KB ciphertext per cadence epoch.

> Production refinement (SPQR): the KEM ciphertext is large, so Signal chunks it
> across several messages and runs the KEM ratchet at its own slower cadence
> than the DH ratchet. Aegis adopts the same chunking once the basic mix works;
> the *mathematics* above is unchanged — only the scheduling of when $d^{+}$
> gains its KEM term.

---

## 5. Sphinx onion routing

Goal: send a fixed-size packet through mixes $n_0,\dots,n_{\nu-1}$
($\nu \le r$, $r$ = max path length) so each hop learns only its predecessor and
successor, never the origin, destination, or payload — and every hop sees a
packet of identical size and distribution.

### 5.1 Node keys and packet shape

Mix $n_i$ has private scalar $x_i$, public $y_i = B^{x_i}$. A packet is

$$
M = (\ \alpha,\ \beta,\ \gamma,\ \delta\ ),
$$

$\alpha$ = a group element (32 B), $\beta$ = encrypted routing header (fixed
length), $\gamma$ = header MAC (16 B), $\delta$ = onion-encrypted payload.

Per-hop symmetric keys are all derived from one shared secret $s_i$ via
domain-separated hashes:

$$
\rho_i = H_\rho(s_i),\quad \mu_i = H_\mu(s_i),\quad \pi_i = H_\pi(s_i),\quad
b_i = H_b(\alpha_i, s_i)\bmod\ell,
$$

where $H_\ast(\cdot) = \mathrm{HKDF}(\varnothing,\ \cdot,\ \texttt{"aegis/sphinx/}\ast\texttt{"},\ L_\ast)$
and $b_i$ is a **blinding scalar**. ($\rho$ keys a stream cipher over the header,
$\mu$ a MAC, $\pi$ the payload cipher.)

### 5.2 Sender precomputation (the blinding chain)

The sender picks one ephemeral scalar $x$ and builds the group elements and
shared secrets *iteratively*, so it never needs a raw product of clamped
scalars:

$$
\begin{aligned}
\alpha_0 &= B^{x} = \texttt{X25519}(x, B) \\
s_0 &= y_0^{x} = \texttt{X25519}(x, y_0), & b_0 &= H_b(\alpha_0, s_0)\\
\alpha_1 &= \alpha_0^{\,b_0} = \texttt{X25519}(b_0, \alpha_0) \\
s_1 &= \texttt{X25519}(b_0,\ \texttt{X25519}(x, y_1)) = y_1^{\,x b_0}, & b_1 &= H_b(\alpha_1, s_1)\\
&\ \vdots \\
\alpha_{i} &= \texttt{X25519}(b_{i-1}, \alpha_{i-1}),\qquad
s_i = \big(\!\!\underbrace{\;X25519(b_{i-1}, \cdots X25519(b_0,}_{\text{apply } b_0..b_{i-1}} X25519(x, y_i))\cdots)\big).
\end{aligned}
$$

So $s_i = y_i^{\,x\,b_0 b_1\cdots b_{i-1}}$ and $\alpha_i = B^{\,x\,b_0\cdots b_{i-1}}$.

### 5.3 Hop processing

Mix $n_i$ receives $(\alpha_i, \beta_i, \gamma_i, \delta_i)$ and:

1. $s_i = \alpha_i^{x_i} = \texttt{X25519}(x_i, \alpha_i)$.
2. Verify $\gamma_i \stackrel?= \mathrm{MAC}_{\mu_i}(\beta_i)$; drop if not
   (integrity + replay defense).
3. Derive $\rho_i$; decrypt the header: right-pad $\beta_i$ with $2\kappa$ zero
   bytes, XOR the $\rho_i$ keystream, and read off
   $(\text{next-hop } n_{i+1},\ \gamma_{i+1},\ \beta_{i+1})$.
4. Blind: $b_i = H_b(\alpha_i, s_i)$, then
   $\alpha_{i+1} = \alpha_i^{b_i} = \texttt{X25519}(b_i, \alpha_i)$.
5. Peel one payload layer: $\delta_{i+1} = \mathrm{Dec}_{\pi_i}(\delta_i)$.
6. Forward $(\alpha_{i+1}, \beta_{i+1}, \gamma_{i+1}, \delta_{i+1})$ to $n_{i+1}$.

**Correctness of the shared secret.** Hop computes
$s_i = \alpha_i^{x_i} = \big(B^{x b_0\cdots b_{i-1}}\big)^{x_i}
= y_i^{\,x b_0\cdots b_{i-1}}$, identical to the sender's $s_i$ in §5.2. The
clamping consistency of §0.1(2) is exactly what guarantees the two derivations
agree, since both are the same sequence of `X25519` calls.

### 5.4 Header construction and the filler (size invariance)

The header must be a **constant length** at every hop, or lengths would leak the
position in the path. Let $\kappa$ = 16 (MAC/security bytes); routing info per
hop is $2\kappa$ bytes; $\beta$ has fixed length $(2r+1)\kappa$.

The sender pre-generates a **filler** $\phi$ so that as each hop XOR-decrypts and
shifts $\beta$, the trailing bytes it exposes are exactly what the *next* MAC was
computed over:

$$
\phi_0 = \varnothing, \qquad
\phi_{i} = \Big(\phi_{i-1}\ \mathbin\|\ 0^{2\kappa}\Big)\ \oplus\ \rho_{i-1}\big[(2r - 2i + 3)\kappa\ ..\ (2r+1)\kappa\big].
$$

Then $\beta$ is built **from the innermost hop outward**: start with the
destination block plus $\phi_{\nu-1}$, and for $i = \nu-1$ down to $0$ set

$$
\beta_i = \Big(\ \text{routing}_i \mathbin\| \gamma_{i+1} \mathbin\| \beta_{i+1}[0..(2r-1)\kappa]\ \Big)\ \oplus\ \rho_i[0..(2r+1)\kappa],
\qquad
\gamma_i = \mathrm{MAC}_{\mu_i}(\beta_i).
$$

The $\rho$-keystream that a hop applies to the zero-padding regenerates exactly
$\phi$, so every intermediate $\gamma$ verifies and the header stays $(2r+1)\kappa$
bytes at every hop. (These are the original Sphinx equations; concrete byte
offsets follow the Sphinx paper / Nym reference. The point for us: it needs only
`X25519`, a stream cipher = ChaCha20 keystream, and `hmac_sha256` — all in
Ciphra.)

### 5.5 Payload and replies

- Payload $\delta$ is wrapped in $\nu$ layers under $\pi_0,\dots,\pi_{\nu-1}$; a
  wide-block construction (LIONESS) or a length-preserving ChaCha layer keeps it
  fixed-size and non-malleable.
- **Anonymous replies** use Sphinx *single-use reply blocks* (SURBs): the
  recipient ships a pre-built header naming a return path back to a pseudonymous
  drop, so the sender can be answered without either side learning the other's
  location.

### 5.6 Security

Each hop's view is $(\alpha_i, \beta_i, \gamma_i, \delta_i)$; $\alpha_i$ is a
uniform group element and, under **DDH**, independent of $\alpha_j$ at other
honest hops, so a hop cannot link its predecessor to its successor. Bit-wise
integrity of $\beta$ (the $\gamma$ MAC) blocks tagging attacks; fixed sizes and
the filler block length/position leakage. Replay is caught by hops caching seen
$s_i$ (or a tag of it) within an epoch.

---

## 6. Loopix mixing and cover traffic

Sphinx hides *routing*; Loopix hides *timing*, defeating an observer who watches
when packets enter and leave.

### 6.1 Poisson mixing (per hop)

Each mix delays every packet independently by

$$
d \sim \mathrm{Exp}(\mu), \qquad f(d) = \mu e^{-\mu d}\ (d \ge 0),\quad \mathbb E[d] = 1/\mu .
$$

A mix is then an **M/M/∞ queue**. Key fact (Poisson thinning/superposition): if
the *aggregate* arrival process at the mix is Poisson and each packet gets an
independent $\mathrm{Exp}(\mu)$ delay, the **departure process is also Poisson
and independent of the specific input timings**. So observing outputs tells the
adversary nothing about which input produced which output — the timing
correlation Sphinx alone leaves open is destroyed.

### 6.2 Client cover traffic

Each client runs three independent Poisson emitters:

$$
\lambda_{\text{payload}}\ (\text{real, when queued}),\quad
\lambda_{\text{drop}}\ (\text{cover to a random mix}),\quad
\lambda_{\text{loop}}\ (\text{cover routed back to self}).
$$

Because independent Poisson streams **superpose** into one Poisson stream of rate
$\lambda = \lambda_{\text{payload}} + \lambda_{\text{drop}} + \lambda_{\text{loop}}$,
the observable output of a client is $\mathrm{Poisson}(\lambda)$ **regardless of
whether it is actually sending a real message**. "Is Alice messaging right now?"
becomes unanswerable against a constant $\lambda$ background. When the real queue
is empty a drop-cover packet is emitted in its place, so the rate never dips.

### 6.3 Loop cover and active-attack detection

$\lambda_{\text{loop}}$ packets are Sphinx-routed in a circuit back to the
sender. If mixes are dropping or delaying traffic (an $(n-1)$ or flooding
attack), a client's own loops fail to return at the expected
$\mathrm{Poisson}(\lambda_{\text{loop}})$ rate — giving each participant a local,
private integrity signal on the network.

### 6.4 The tunable

Anonymity scales with $\lambda$ (more cover) and $1/\mu$ (more delay); latency
and bandwidth scale the same way. Aegis exposes:

- **fast** — Sphinx routing only, $\mu \to \infty$ (no added delay), minimal
  cover. Low latency, resists per-hop linking but not a both-ends timing
  adversary.
- **paranoid** — full Loopix: finite $\mu$, all three cover streams. Resists a
  global passive adversary at a latency cost of a few $\times\,1/\mu$ per hop.

This trade is fundamental (§1.3 of the protocol doc): there is no free
metadata protection.

---

## 7. Security-assumption summary

| Process | Correctness rests on | Confidentiality / anonymity rests on |
|---|---|---|
| Stealth address (§1) | commutativity of scalar mult | DDH (Curve25519) + HKDF-as-RO |
| PQXDH (§2) | DH commutativity + ML-KEM correctness | Gap-CDH **and** ML-KEM-768 IND-CCA2 (dual-PRF HKDF) |
| Chain ratchet (§3.1) | HMAC determinism | HMAC/HKDF PRF-security (one-way ⇒ FS) |
| DH ratchet (§3.2) | DH commutativity | CDH (⇒ post-compromise healing) |
| PQ ratchet (§4) | ML-KEM correctness | ML-KEM-768 IND-CCA2 (ongoing PQ) |
| Sphinx (§5) | clamping-consistent scalar mult | DDH + MAC unforgeability + PRP |
| Loopix (§6) | Poisson superposition/thinning | statistical indistinguishability of Poisson streams |

Two independent hardness families back confidentiality end to end — **elliptic
DH** and **Module-LWE** — so the whole system holds if *either* survives.

---

*Status: v0 math reference. Byte-exact parameters (Sphinx field lengths, KEM
chunking cadence, Argon2/HKDF labels) are fixed here as the labels above and
finalized against the reference implementations during Phase 0–3.*
