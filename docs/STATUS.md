# Status

Last updated: 2026-07-08

## Current focus

**H1 runtime hardening** in progress. **H1.1–H1.2 done:** threaded RTS (§7.6);
symlink sandbox containment via `canonicalizePath` + root-prefix check on all
direct file ops (§7.1, §6.2). Remaining: model-catalog step keys (H1.3),
sub-workflow scope (H1.4), crash handler (H1.5). See spec §14 and
[TASKS.md](TASKS.md) → H1.

## Done recently

- **H1.2:** `Hwfi.Runtime.Workspace` — `resolveContainedPath` (lexical +
  canonical containment) on read/write/list/mutation/navigation roots; module
  comment aligned with spec §7.1; symlink escape regression tests; 213 tests
  green.
- **H1.1:** `hwfi.cabal` — `-threaded -rtsopts "-with-rtsopts=-N"` on
  `executable hwfi` and `test-suite hwfi-test`.
- M8 control flow complete; spec aligned for H1 backlog (§14).

## Blockers

- None.

## Next up

[TASKS.md](TASKS.md) → H1.3–H1.5, then optional items.
