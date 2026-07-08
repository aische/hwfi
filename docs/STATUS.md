# Status

Last updated: 2026-07-08

## Current focus

**M8 complete.** Next work is **H1 runtime hardening** from the 2026-07-08
code review ([code-issues.md](code-issues.md)): threaded RTS, symlink sandbox
containment, model-catalog step-key invalidation, sub-workflow scope threading,
and deliberate crash handling. Normative requirements are in spec §4.1, §6.2,
§7.1/§7.3/§7.6, §8.1/§8.2/§8.3; gaps tracked in spec §14 and
[TASKS.md](TASKS.md) → H1.

Carried-over optional items (agent state serialisation §8.2.1, OS-level `exec`
isolation §7.5, `Bytes` I/O) remain after H1.

## Done recently

- **DEC-1 closed:** block-local identifier scoping (spec §4.2).
- M8 control flow (`if`/`foreach`/`par`): parsing, checker, executor, trace,
  `examples/control-flow`; 210 tests.
- Spec updated for H1 hardening backlog (§14 + normative fixes in §4.1, §6–8).

## Blockers

- None.

## Notes / decisions

- **H1 scope threading (§4.1):** spec requires caller scope prefix at
  sub-workflow entry; engine still resets to `""` (H1.4).
- **H1 symlink sandbox (§7.1):** spec requires canonical containment after
  lexical resolve; engine is lexical-only today (H1.2). M4 log entry claiming
  lexical resolution prevents symlink escape is superseded.
- Control flow is value-producing; `par` is order-preserving, lowest-index
  abort; durable-workspace invariant holds through loops/branches.

## Next up

[TASKS.md](TASKS.md) → H1, then optional items / M9+ backlog.
