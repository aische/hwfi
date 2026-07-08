# Status

Last updated: 2026-07-08

## Current focus

**H1 runtime hardening** in progress. **H1.1–H1.3 done:** threaded RTS (§7.6); symlink
sandbox containment (§7.1, §6.2); model-catalog fingerprint in one-shot
`builtin/llm-*` step-keys (§8.1, §7.3). Remaining: sub-workflow scope (H1.4),
crash handler (H1.5). See spec §14 and [TASKS.md](TASKS.md) → H1.

## Done recently

- **H1.3:** `stepKeyFor` folds `model-catalog-fp` into `ctx-projection` for
  `builtin/llm-generate`/`llm-chat`/`llm-gen-object` via
  `Gateways.oneShotLlmCtxProjection`; resume test + fingerprint unit tests; 216
  tests green.
- **H1.2:** `Hwfi.Runtime.Workspace` — `resolveContainedPath` on all direct file
  ops; symlink escape regression tests.
- **H1.1:** `hwfi.cabal` — `-threaded -rtsopts "-with-rtsopts=-N"` on executable
  and test-suite.

## Blockers

- None.

## Next up

[TASKS.md](TASKS.md) → H1.4–H1.5, then optional items.
