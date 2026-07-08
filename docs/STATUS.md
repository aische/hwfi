# Status

Last updated: 2026-07-08

## Current focus

**H1 runtime hardening complete** (code review 2026-07-08). All items H1.1–H1.5
shipped: threaded RTS (§7.6); symlink sandbox containment (§7.1, §6.2);
model-catalog fingerprint in one-shot `builtin/llm-*` step-keys (§8.1, §7.3);
sub-workflow scope threading (§4.1); crash handler with `run-end` (`crashed`) +
`PhaseCrashed` on unexpected exceptions (§8.2, §8.3.2). 223 tests green.

## Done recently

- **H1.5:** `tryAny` around `runWorkflow` in `performRun`/`performResume`;
  `finishCrash` emits `error` (`internal`), `run-end` (`crashed`), sets
  `run.json.status: crashed`; `RunStatus` extended; resume-from-crash test.
- **H1.4:** control-flow scope threaded into sub-workflow/tool bodies (§4.1).

## Blockers

- None.

## Next up

[TASKS.md](TASKS.md) → optional items (8.g, 9.x).
