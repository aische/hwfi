# Status

Last updated: 2026-07-08

## Current focus

**H1 runtime hardening** in progress. **H1.1–H1.4 done:** threaded RTS (§7.6);
symlink sandbox containment (§7.1, §6.2); model-catalog fingerprint in one-shot
`builtin/llm-*` step-keys (§8.1, §7.3); sub-workflow scope threading (§4.1).
Remaining: crash handler (H1.5). See spec §14 and [TASKS.md](TASKS.md) → H1.

## Done recently

- **H1.4:** `runWorkflow` and `dispatchResolved` thread the caller's
  control-flow scope prefix into sub-workflow/tool bodies (§4.1); agent tool
  dispatch inherits the same scope; four regression tests in
  `ControlFlowSpec` (foreach/par + resume); 220 tests green.
- **H1.3:** `stepKeyFor` folds `model-catalog-fp` into `ctx-projection` for
  `builtin/llm-generate`/`llm-chat`/`llm-gen-object` via
  `Gateways.oneShotLlmCtxProjection`; resume test + fingerprint unit tests.

## Blockers

- None.

## Next up

[TASKS.md](TASKS.md) → H1.5, then optional items.
