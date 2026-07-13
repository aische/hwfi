# Status

Last updated: 2026-07-13

## Current focus

**v2 runtime (cursor + frames)** — M6 done: single resume story via
`machine.json` + `MachineRun`. Design: [execution-model.md](execution-model.md).

**M5** (DB / server `ProjectStore`) remains deferred — optional, not blocking
local filesystem mode.

## Done recently

- **M6** — Removed step-key cache path, `Executor`, `hwfi cache *`; resume via
  snapshot; while-pred pinning from trace; trace parity (if/try/par/while).
- **M4** — CLI `continue` / `step` / `resume`; `MachineRun`.
- **M3** — real `par`, cooperative confirm, per-branch snapshots.
- **M2** — agent `CurAgent` stepping; snapshot resume.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — M5 (optional) or v1.1 backlog.
