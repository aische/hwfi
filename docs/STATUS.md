# Status

Last updated: 2026-07-09

## Current focus

**9.3 done; next is 9.4 (skills).** Cross-run trace builtins are implemented.
Skill extraction (9.4.1–9.4.3) is specified but not started.

## Done recently

- **9.3 cross-run traces (2026-07-09):** `builtin/list-runs`,
  `builtin/read-run-trace` (§6.5); `RunStore.listRuns` / `readRunTrace`;
  non-cacheable; agent-eligible; `file-io` trace events; current run reads
  from in-memory tracer (avoids locked `trace.jsonl`). Tests A36/A37 in
  `CrossRunTraceSpec`. 257 tests green.
- **§6.5–§6.6 skills + traces spec (2026-07-09):** Skill model and
  `trace-slice` design. See [skills-design.md](skills-design.md).
- **9.2 eval-workflow (2026-07-09):** `builtin/eval-workflow` (§6.4). Tests
  A34/A35.

## Blockers

- None.

## Next up

[TASKS.md](TASKS.md) → 9.4.1–9.4.3; optional 9.1, 9.4.4, 9.5–9.6, 9.9–9.14.
