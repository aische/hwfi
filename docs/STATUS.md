# Status

Last updated: 2026-07-12

## Current focus

**v1.1 backlog** — 9.12 cache invalidation UX is next. 9.9–9.11 shipped.

## Done recently

- **9.9 control-flow error handling:** `try`/`catch` (parse, check, exec,
  `try-branch` trace, resume); `par(on_error = "collect")` envelope results;
  ControlFlowSpec T1–T7 + collect test (306 tests).
- **9.11 inline `while` bodies:** `body = { … }` sugar; `${carry}` in inline
  blocks.
- **9.10 record plumbing:** `record-merge` / `record-filter` / `record-map`.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) → 9.12 cache invalidation UX, then 9.14 WorkflowRef
patterns.
