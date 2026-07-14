# Status

Last updated: 2026-07-14

## Current focus

**v2 runtime (cursor + frames)** — M6 done: single resume story via
`machine.json` + `MachineRun`. Design: [execution-model.md](execution-model.md).

**Semantic review (research)** — design captured in
[semantic-check-design.md](semantic-check-design.md): review as an ordinary
workflow; Tier 1–4 general-purpose builtins backlog in [TASKS.md](TASKS.md).
Implementation not started.

**M5** (DB / server `ProjectStore`) remains deferred — optional, not blocking
local filesystem mode.

## Done recently

- **Merge-prep docs** — CHANGELOG `[Unreleased]` (0.2.0.0 breaking changes),
  upgrade guide in `caching-and-resume.md` / README; fixed stale `Executor`
  references in spec, tool-use, skills-design.
- **Per-transition stepping** — `hwfi step` / `hwfi run --step` halt after each
  transition (workflow statement, agent model call, or agent tool call).
- **`hwfi run --step`** — start stepping without Ctrl+C; prints `run-id` on stderr.
- **CLI UX** — bare `hwfi` shows help; resume command is `hwfi resume`.
- **Resume robustness** — Collapse step dispatch into one transition; checkpoint
  before agent LLM/tool I/O; flush snapshot on crash/interrupt.
- **Resume snapshot fix** — Tagged `RValue` encoding in `machine.json`.
- **M6 cleanup** — Purged stale step-cache docs/examples.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — semantic review builtins (Tier 1 first), M5 (optional),
or v1.1 backlog.
