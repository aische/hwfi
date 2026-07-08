# Status

Last updated: 2026-07-08

## Current focus

**H1 runtime hardening** in progress. **H1.1 done:** executable and test
suite linked with threaded RTS (`-threaded`, `-with-rtsopts=-N`, §7.6).
Remaining: symlink sandbox (H1.2), model-catalog step keys (H1.3),
sub-workflow scope (H1.4), crash handler (H1.5). See spec §14 and
[TASKS.md](TASKS.md) → H1.

## Done recently

- **H1.1:** `hwfi.cabal` — `-threaded -rtsopts "-with-rtsopts=-N"` on
  `executable hwfi` and `test-suite hwfi-test`; 210 tests green.
- M8 control flow complete; spec aligned for H1 backlog (§14).

## Blockers

- None.

## Next up

[TASKS.md](TASKS.md) → H1.2–H1.5, then optional items.
