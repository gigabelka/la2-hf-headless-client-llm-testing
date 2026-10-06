---
name: run
description: Run the headless L2 client end-to-end (npm run dev) and parse the single === REPORT === block. Use when the client needs to be run or verified against a live server.
---

Run the L2 client and report the result. This repo is **Windows/PowerShell-first**.

## Process

### 1. Preconditions
- `package.json` / `src/` exist and `npm install` has run. If `src/` is empty or absent, build it first via
  the `build-l2` skill — there is nothing to run yet.
- `.env` holds real credentials (never overwrite it).
- `npx tsc --noEmit` is clean — fix type errors before running.

### 2. Run
```powershell
npm run dev
```
The whole flow runs in one pass (config → crypto self-tests → login → enter world → IN_GAME →
60s keepalive). The process stays alive ~60s for the keepalive, so allow a generous timeout (~75s).
A failing run ends inside the 45s watchdog of PLANE.md `## TIMEOUTS & LIVENESS`, so anything still
running past ~80s without an `IN_GAME` line means the timeouts themselves are missing — that is a
`debug-l2` case (guardrails → Timeouts), not a slow server.

### 3. Parse the report
Locate the single `=== REPORT ===` block in stdout and read:
- `status:` — `PASS` or `FAIL`
- `self-tests: <passed>/<total>`
- `state-path:` — the FSM path reached (`IDLE → … → IN_GAME` on success)
- `notes:` — the first failing assertion / error, if any

Success criteria (README Definition of Done): `IN_GAME` printed, connection held ~60s, final report
`status: PASS`, and `npx tsc --noEmit` clean. The "≥1 ping answered" requirement is verified
**indirectly** — the report has no ping counter, but a missed pong disconnects the client well before
60s, so holding the connection for ~60s with `status: PASS` implies pings were answered (ping-related
stdout lines, if present, are extra confirmation).

### 4. Report back
State PASS/FAIL, the self-test count, and — on FAIL — the `notes:` line and the last state reached.
On FAIL, hand off to the `debug-l2` skill with the observed symptom.
