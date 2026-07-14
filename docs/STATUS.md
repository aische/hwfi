# Status

Last updated: 2026-07-14

## Current focus

**v2 runtime (cursor + frames)** — M6 done: single resume story via
`machine.json` + `MachineRun`. Design: [execution-model.md](execution-model.md).

**M5** (DB / server `ProjectStore`) remains deferred — optional, not blocking
local filesystem mode.

## Done recently

- **Resume snapshot fix** — Tagged `RValue` encoding in `machine.json` preserves
  typed bindings (`VRecord`/`VString`/…).
- **M6 cleanup** — Purged stale step-cache docs/examples; fixed runtime
  comments; wired `cacheable` trace flags from checker; removed dead
  `aeStepKey` / `atFingerprint` fields.
- **M6** — Removed step-key cache path, `Executor`, `hwfi cache *`; resume via
  snapshot; while-pred pinning from trace; trace parity (if/try/par/while).

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — M5 (optional) or v1.1 backlog.
