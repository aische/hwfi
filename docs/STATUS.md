# Status

Last updated: 2026-07-12

## Current focus

**v1.1 backlog** — 9.10 record plumbing, 9.11 loop sugar (`range`, inline
`while` bodies) shipped; 9.9 (`try`/recover) still needs resume/cache design.

## Done recently

- **Inline `while` bodies (9.11):** `body = { … }` sugar alongside callee
  bodies; `${carry}` in inline blocks; parse/check/exec tests.
- **Record plumbing (9.10):** `builtin/record-merge`, `record-filter`,
  `record-map` with typed checker support.
- **Counted loops (9.11):** `range(n)` → `List<Int>` for `foreach`/`par`.
- **v0.1.0.0 tag (2026-07-10):** first release with tutorials, examples, and
  `CHANGELOG.md`.

## Blockers

- **9.9** — workflow `try`/recover and `par` continue-on-failure need spec on
  step-keys, trace events, and resume replay before coding.

## Next up

[TASKS.md](TASKS.md) → 9.9 control-flow error handling, 9.12 cache invalidation UX.
