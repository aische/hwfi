# Status

Last updated: 2026-07-12

## Current focus

**v1.1 backlog** — 9.9 (`try`/recover, `par` collect-errors) is **specified**
(§4.4, §4.1.1) and ready to implement. 9.10–9.11 shipped.

## Done recently

- **9.9 spec:** `try`/`catch` resume/cache/trace rules (§4.4); `par(on_error =
  "collect")` envelope semantics (§4.1.1).
- **Inline `while` bodies (9.11):** `body = { … }` sugar; `${carry}` in inline
  blocks.
- **Record plumbing (9.10):** `record-merge` / `record-filter` / `record-map`.
- **Counted loops (9.11):** `range(n)` → `List<Int>`.

## Blockers

None for 9.9 implementation.

## Next up

[TASKS.md](TASKS.md) → implement 9.9 (`try` first, then `par` collect-errors),
then 9.12 cache invalidation UX.
