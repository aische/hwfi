# Status

Last updated: 2026-07-09

## Current focus

**§6.5–§6.6 specified (9.3 / 9.4 design).** Cross-run trace builtins and
skill extraction are designed but not implemented. Next implementation: 9.3
→ 9.4.1 → 9.4.2 → 9.4.3.

## Done recently

- **§6.5–§6.6 skills + traces spec (2026-07-09):** Cross-run
  `list-runs` / `read-run-trace`; skill model (`skills/` declarations +
  provenance metadata); `trace-slice`; Mode A (agent-driven) and optional
  Mode B (`extract-skill`). Acceptance A36–A40. See [skills-design.md](skills-design.md).
- **9.2 eval-workflow (2026-07-09):** `builtin/eval-workflow` (§6.4) — parse,
  type-check, and run dynamic workflow source; `{ ok, outputs, errors }` on
  recoverable failure; non-cacheable; agent-eligible. Tests A34/A35 in
  `EvalWorkflowSpec`. 249 tests green.

## Blockers

- None.

## Next up

[TASKS.md](TASKS.md) → implement 9.3, then 9.4.1–9.4.3; optional 9.1, 9.4.4,
9.5–9.6, 9.9–9.14.
