# Status

Last updated: 2026-07-09

## Current focus

**M9 complete.** Optional items next: 8.g, 9.1–9.6. 243 tests green.

## Done recently

- **M9 `while` loops (§4.3):** AST/parser (`WhileStmt`), checker (predicate
  shape, `carry`, callees in graph/fps), executor (`execWhile`, scope
  `#i/p/`/`#i/b/`, decision-key pinning), trace (`while-pred`, optional
  `loop-start.count`), tests A30/A31/A33 + parser test (2026-07-09).
- **§4.3** spec drafted; M1–M8, H1, 9.7/9.8 complete.

## Blockers

- None.

## Next up

[TASKS.md](TASKS.md) → optional 8.g / 9.1–9.6. A32 (agent-in-predicate resume)
is covered by the same decision-pinning path as A31; no separate integration
test yet.
