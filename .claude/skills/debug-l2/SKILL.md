---
name: debug-l2
description: Diagnose a failing run of the headless L2 client by mapping the symptom to PLANE.md's TROUBLESHOOTING table, verifying crypto in isolation first. Use when the run reports FAIL, the client disconnects, packets look scrambled, or IN_GAME never prints.
argument-hint: "What symptom are you seeing?"
---

Diagnose the L2 client symptom: `$ARGUMENTS`. If that is empty — this skill was triggered
automatically rather than typed as `/debug-l2` — take the symptom from the last `=== REPORT ===`
block (`notes:`, `state-path:`) and the output above it instead, and say which symptom you picked.
Source of truth for fixes is the **TROUBLESHOOTING**
section of [PLANE.md](../../../PLANE.md); constraints are in the `l2-guardrails` skill; build order is `build-l2`.

## Process

### 1. Build a tight feedback loop first
A **tight** loop goes red on _this_ bug and runs in milliseconds. The tightest one here is the crypto
round-trip — it needs no socket, so it isolates the crypto from every network cause before you touch either:
- `blowfishDecrypt(blowfishEncrypt(x, k), k).equals(x)`
- `gameCrypt.decrypt(gameCrypt.encrypt(x)).equals(x)` (two instances, same 8-byte key, `enabled=true`)

Run the full suite in isolation with **`npm run selftest`** (`src/selftest.ts`) — no socket is
opened, unlike `npm run dev`. It also carries the **KATs** (known-answer vectors).
A round-trip stays green under any symmetric transcription error, so a green round-trip next to a red
KAT still means broken crypto. If anything goes red, the module was not pasted verbatim — re-copy it
from PLANE.md, never edit the expected hex, and stop; do not chase the socket over broken crypto.
Only once all 12 checks stay green do you move to the table below.

### 2. Map the symptom → cause → where the fix lives

The exact values (offsets, byte counts, key tails, field order) live in **one place** — the
`l2-guardrails` skill, backed by PLANE.md. This table only routes a symptom to the right rule;
read that rule, don't reconstruct it from memory.

| Symptom | Likely cause | Fix lives in |
| ------- | ------------ | ------------ |
| Blowfish garbage / round-trip fails | crypto not pasted verbatim / `node:crypto` / padding added | guardrails → Login crypto; PLANE.md → LoginCrypt |
| Init won't decode | wrong Init decode path | guardrails → Login crypto (Init) |
| LoginFail right after AuthLogin | RSA setup (modulus / padding / offsets) | guardrails → Login crypto (RSA) |
| Server drops you on login (checksum) | outgoing login packet build order | guardrails → Login crypto (outgoing) |
| Nothing happens on game server | textbook opcodes used | guardrails → Opcodes; PLANE.md → OPCODE MAP |
| AuthRequest rejected | wrong session-key field order | guardrails → Game FSM (AuthRequest) |
| CharacterSelected ignored | missing zero padding | guardrails → Game FSM (CharacterSelected) |
| No UserInfo / silent disconnect | enter-world sequence incomplete | guardrails → Game FSM (enter world) |
| Game packets scrambled | crypt flag ignored / wrong key tail | guardrails → Game crypto |
| Disconnect at ~60s | pings not answered | guardrails → Keepalive |
| Server rejects frames | double length prefix | guardrails → Framing |
| Duplicate EnterWorld warning | UserInfo arrived before CharSelected confirm | guardrails → Game FSM (skipped CharSelected) |
| Run hangs / never settles | run promise left pending on close | guardrails → Game FSM (server close) |
| Run stalls in one state until the watchdog | an unbounded wait, or silence mistaken for a packet (GGAuth) | guardrails → Timeouts |
| Opcode looks wrong, every field shifted by 2 | frame parsed instead of the body | guardrails → Packet pipeline |
| Game stream decodes, then turns to noise | an ignored packet was dropped before decryption | guardrails → Packet pipeline |
| A KAT is red but its round-trip is green | module not pasted verbatim (one constant/offset) | guardrails → Login crypto / Game crypto |
| `npm run dev` dies before any output | module format (`type`, missing `.ts` in an import) | guardrails → TypeScript / build |
| `IN_GAME` printed but report says FAIL | `notes` passed on a successful run | guardrails → Flow & config |

### 3. Instrument the failing transition
The FSM already logs transitions via `logState(from, to)`. Add a temporary hexdump
(`console.error(buf.subarray(0, n).toString('hex'))`) at the opcode dispatch of the state where it
stalls, compare the bytes against the PROTOCOL REFERENCE layout for that packet, then remove the
instrumentation once fixed.

**Never dump the decrypted `AuthLogin` plaintext** — it carries the login/password in ASCII at
`0x5E`/`0x6E`. If that packet must be inspected, zero those byte ranges before printing.

### 4. Re-run
After the fix, re-run via the `run` skill and confirm the report flips to `status: PASS`.
