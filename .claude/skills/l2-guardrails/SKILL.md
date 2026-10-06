---
name: l2-guardrails
description: The HARD CONSTRAINTS and recurring failure modes for the headless Lineage 2 (HighFive, protocol 267) client in this repo. Use whenever writing or reviewing packet framing, opcodes, login/game crypto, the login/game FSMs, or keepalive code — these are the mistakes that make the build fail. Source of truth: PLANE.md.
---

Fast checklist to keep the L2 client build correct. Each item cites where PLANE.md explains it —
read that section when in doubt; **never invent values.** This skill owns the *constraints*; for the
*order* of building the client from scratch, use the `build-l2` skill.

## Framing & wire format (PLANE.md → HARD CONSTRAINTS)
- Every packet is `[uint16LE size][1-byte opcode][payload]`; the size field **includes itself**.
- `Connection.send(body)` prepends the 2-byte LE length internally. **Never prepend length yourself** —
  double-prefixing corrupts every frame.
- All integers little-endian. Strings UTF-16LE, null-terminated (two `0x00`), unless stated otherwise.
- Client extended packets: `[0xD0][2-byte sub-opcode LE][…]` — the sub-opcode is a `uint16LE`
  however small it looks (`RequestKeyMapping` → `0xD0` + `writeUInt16LE(0x0021)`, never `0x21`).
  Server extended packets are prefixed `0xFE` — treat `0xFE 0x00D3` as `NetPingRequest`. Store
  `ExtendedOpcode=0xD0`, `ServerExtendedOpcode=0xFE`.

## Packet pipeline (PLANE.md → PACKET PIPELINE)
- `onPacket(frame)` delivers the frame **with** the 2-byte length; `send(body)` takes the body
  **without** it. Receive = `frame.subarray(2)` → decrypt the body → `new PacketReader(plain)` →
  `readUInt8()` is the opcode. **Every offset in the protocol tables starts at that opcode**, so
  parsing the frame directly shifts every field by two bytes — which looks like broken crypto.
- Send = `PacketWriter` body → `crypt.encrypt(body)` → `conn.send(enc)`. The length is never
  encrypted and is measured on the encrypted body.
- Login: first packet → `decryptInit`, every later packet → `decrypt` (identity before
  `setSessionKey`). Game: `CryptInit` is plaintext, everything after it goes through `GameCrypt`.
  Call `setSessionKey` while handling `Init`, before the first send.
- **Decrypt every received body exactly once, in arrival order — including ignored ones.** Both
  `GameCrypt` keys shift by the size of each processed body; dropping an unknown packet before
  decrypting it desyncs the stream for good.
- Any body handed to Blowfish must be a multiple of 8 — an odd length is a framing bug, fail with
  that length in `notes` instead of letting `blowfishDecrypt` throw.

## Timeouts (PLANE.md → TIMEOUTS & LIVENESS)
- 10 s per TCP connect, 15 s per `WAIT_*` state, 45 s whole-run watchdog to `IN_GAME`, then 60 s
  keepalive counted **from the `IN_GAME` line**. A hang is a bug, never a slow server.
- `WAIT_GG_AUTH` is the exception: silence is the normal answer from a server without GameGuard.
  After 3 s with no `GGAuth 0x0B` — or on any other opcode — set `ggResponse = 0`, continue, and
  re-dispatch that packet in the new state. Never wait for "`LoginOk`-shaped data": `LoginOk`
  cannot arrive before `RequestAuthLogin` is sent.
- Every exit path settles the stage promise exactly once (success, `LoginFail`/`PlayFail`, timeout,
  socket `error`, `onClose` before `UserInfo`). Clear every timer before resolving or the process
  will not exit 0.

## Opcodes (PLANE.md → OPCODE MAP)
- Use the **HighFive** map from PLANE.md, **never textbook L2 opcodes**. Wrong opcodes = silent
  no-op on the game server.

## Login crypto (PLANE.md → LoginCrypt / TROUBLESHOOTING)
- Init: static-key Blowfish decrypt → `decXORPass` → drop the last 8 bytes. No checksum on Init.
- Copy Blowfish / NewCrypt / ScrambledRsaKey / RsaCrypt / LoginCrypt / GameCrypt **verbatim**. Blowfish is
  ECB, no padding, 8-byte blocks, pure TS (no `node:crypto`); RsaCrypt is the exception and uses `node:crypto`
  for RSA. `GameCrypt.ts` lives at `src/crypto/GameCrypt.ts`.
- Self-tests run **before any socket I/O**, and each module is checked twice — round-trip **and**
  KAT (known-answer vector). A round-trip stays green under any *symmetric* transcription error, so
  the KAT is what actually guards the copy. A red KAT = not pasted verbatim; re-copy the module and
  **never** edit the expected hex.
  - `runLoginCryptoSelfTests()`: Blowfish round-trip + KAT, LoginCrypt round-trip + KAT,
    `decryptInit` KAT.
  - `runGameCryptoSelfTests()`: GameCrypt round-trip + KAT for the 1st and 2nd packet, the 20-byte
    static-tail vector (the only one that touches `key[8..15]`), and disabled-passthrough.
- RSA: unscramble the 128-byte modulus first, `RSA_NO_PADDING`, 128-byte plaintext with login at
  `0x5E`, password at `0x6E` (ASCII).
- Outgoing login packets after the session key: pad to 4, append 8 zero bytes, pad to 8, write the XOR
  checksum into the 4 bytes before the final pad, then Blowfish-encrypt. Length prefix is measured on
  the **encrypted** body.
- Skipped GGAuth: see Timeouts above — the trigger is 3 s of silence (or any non-`GGAuth` opcode),
  not "`LoginOk`-shaped data".

## Game crypto (PLANE.md → HARD CONSTRAINTS #7 / GameCrypt)
- **Flag-driven**: after `CryptInit 0x2E`, `gameCrypt.init(xorKey, encryptionFlag !== 0)`. Apply the
  16-byte shifting XOR to every subsequent body only when the flag is non-zero; plaintext otherwise.
- `ProtocolVersion 0x0E` is always sent **raw**, before CryptInit.
- Static key tail: `c8 27 93 01 a1 6c 31 97`. Verify `decrypt(encrypt(x)).equals(x)`.

## Game FSM & enter-world (PLANE.md → PART B / TROUBLESHOOTING)
- `AuthRequest 0x2B` key order: `playOkId2, playOkId1, loginOkId1, loginOkId2`. **No trailing language field.**
- `CharacterSelected 0x12`: slot index + **exactly 14 zero bytes**.
- Enter world = `RequestKeyMapping` (`0xD0 0x0021`) **then** `EnterWorld 0x11` + **exactly 104 zero bytes**.
  Skipping either → no `UserInfo`, silent disconnect.
- Skipped CharSelected: if `UserInfo 0x32` arrives while waiting for the CharSelected confirm, send
  the enter-world sequence and treat **that same packet** as the `UserInfo` — print `IN_GAME` and go
  straight to `IN_GAME`. Waiting for a *second* `0x32` is the bug here: it never comes, and
  `WAIT_USER_INFO` times out on a healthy connection. Still **guard RequestKeyMapping/EnterWorld to
  send at most once**.
- Tolerate up to 10 unknown packets **per entry into a `WAIT_*` state** (in both FSMs, not just
  around character selection; the counter resets on every transition): decrypt the body, log the
  opcode, drop it; the 11th within one entry is a FAIL carrying the opcode and the state.
  `WAIT_USER_INFO` and `IN_GAME` are **exempt from the counter entirely** — a HighFive server sends
  dozens of ignorable packets between `EnterWorld` and `UserInfo`, so a budget there fails a correct
  client; in those two states drop every non-ping packet silently and don't count it.
- `assertState` guards a transition, never an incoming opcode. Used as a packet filter it turns
  every documented edge case (skipped `GGAuth`, skipped `CharSelected`) into a crash.
- If the server closes before `UserInfo`, settle the run promise (never leave it pending) and report FAIL.

## Keepalive
- In **every** state from `WAIT_CRYPT_INIT` onwards (not just `WAIT_USER_INFO`/`IN_GAME`), reply to
  every `0xD3` (or `0xFE 0x00D3`) with the
  pong `0xA8 + D pingId + D 0 + D 0x00080000` — a 13-byte body, 15 bytes on the wire. Missing pongs
  = disconnect at ~60s.

## Flow & config (PLANE.md → PROJECT SETUP / Entry point)
- `index.ts` is a single linear program — one `npm run dev` runs config → self-tests → login → game →
  final report. **No `PHASE` env var, no per-stage report.**
- `config.ts` loads `.env` via `dotenv`, `parseInt` numbers, throws a clear error on any missing value.
  Do not overwrite the existing `.env` — only `.env.example` is generated.
- One `report(...)` per run, and `notes` is the failure channel: a non-empty `notes` makes the
  status `FAIL` even when everything worked. On success pass only `(statePath, artifacts)`.
- **Game address:** the game host always comes from the picked `ServerList` record. So does the port —
  the record carries `D port`; `L2_GAME_PORT` from `.env` is only the fallback when that value is
  unusable (0 / absent). `LoginResult.gameHost`/`gamePort` is what the game stage connects to.
  Each record is exactly 21 bytes; `b[4] ip` is four octets in order (`readBytes(4)`, never a `D`,
  or the address comes out reversed); no record matching `L2_SERVER_ID` is a FAIL listing the ids
  that were found — never fall back to the first record.

## TypeScript / build (PLANE.md → PROJECT SETUP / MODULE CONTRACTS)
- **Runner is native TS**: `npm run dev` = `node --experimental-strip-types src/index.ts`. No `ts-node`.
- **Module format**: `package.json` `"type": "module"` **and** an explicit `.ts` extension on every
  relative import. This is the only combination Node 24 runs: `"type": "commonjs"` + ESM `import` is
  `SyntaxError: Cannot use import statement outside a module`, and `"type": "module"` + an
  extensionless relative import is `ERR_MODULE_NOT_FOUND`. `tsconfig` uses `module`/
  `moduleResolution` `nodenext` with `allowImportingTsExtensions` +
  `rewriteRelativeImportExtensions`, so `tsc` rewrites those specifiers to `.js` in `dist/`.
- Node only *strips* types — **no `enum`, no `namespace`, no constructor parameter-properties**
  (`constructor(private x: T)`); declare fields in the class body. `Opcodes.ts` is `OPCODES` as a
  `const … as const` object. `tsconfig` sets `isolatedModules: true` to catch violations at typecheck.
- **`verbatimModuleSyntax` is on, so every type import needs the `type` keyword.** `src/types.ts`
  exports only types: `import { Config } from "../types.ts"` is a hard `TS1484` failure, and
  `import type { Config } from "../types.ts"` is the only form that compiles. A module needing a
  value and a type uses two statements. This is the most common first-`tsc` failure in this build.
- **Shared types live only in `src/types.ts`** (`Config`, `LoginResult`, `GameInput`, `Artifacts`,
  FSM state unions). `login/` and `game/` **never import types or logic from each other** — thread
  shared data through `index.ts`. Don't redefine these types locally.
  **One allowed exception:** PLANE.md puts the *whole* opcode map (login and game alike) in
  `src/game/Opcodes.ts`, so `login/LoginClient.ts` importing `OPCODES` from there is correct and
  required — not a violation of this rule.
- `net/Connection.ts`, `PacketReader.ts`, `PacketWriter.ts`, `Opcodes.ts`, `DebugTools.ts`,
  `crypto/selfTests.ts`, `types.ts` are **COPY VERBATIM**
  now — paste them, don't re-derive. `readInt64LE()` returns `bigint`; `writeInt64LE(v: bigint)`.
  Self-test functions return `void`.
- `strict` is on; **`noUncheckedIndexedAccess` stays off** — the verbatim crypto's `!` assertions are
  correct under this config, don't strip them and don't enable the flag.
- Match every exported signature in PLANE.md → `MODULE CONTRACTS` so cross-module wiring typechecks
  on the first `tsc` pass. Dependency versions in `package.json` are pinned exact (no `^`).

## Self-tests
- The crypto self-tests live in `crypto/selfTests.ts`; `debug/DebugTools.ts` holds only
  `check`/`selfTestCounts`/`logState`/`assertState`/`report` and imports nothing but `types.ts`.
- Run crypto self-tests **before any socket I/O**. A failing check — round-trip or KAT — stops the
  run and prints the report; never open sockets with broken crypto.
- The "before any socket" rule applies to the **crypto** self-tests only. PLANE.md also mandates
  exactly two runtime `check(...)` calls that fire **during** the socket phase —
  `modulus is 128 bytes` (once the modulus is unscrambled) and `charCount >= 1` (after
  CharSelectInfo) — and they feed the same `self-tests: X/Y` counter in the report. That is correct
  behavior, not a violation. Those two are the whole list: don't invent extra runtime checks.
  A fully green run prints `self-tests: 14/14` (12 crypto + these 2).
