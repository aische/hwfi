# Status

Last updated: 2026-07-09

## Current focus

**8.g complete.** Optional items next: 9.1–9.6.

## Done recently

- **8.g agent checkpoint (2026-07-09):** Persist agent-loop `messages` +
  `next_round` under the agent step-key on each completed round; reload on
  resume to skip re-walking earlier rounds (§8.2.1 perf optimization).
  Cleared on successful termination. Test in `AgentSpec`.
- **H1 verification (2026-07-09):** [h1-verification.md](h1-verification.md)
  maps H1.1–H1.5 to tests; [code-issues.md](code-issues.md) and
  [spec-issues.md](spec-issues.md) reconciled; spec §14 updated.
- **M9 `while` loops (§4.3):** AST/parser, checker, executor, trace, tests
  A30/A31/A33 (2026-07-09).

## Blockers

- None.

## Next up

[TASKS.md](TASKS.md) → optional 9.1–9.6. Perf hardening (§14) only if
long agent runs become painful.
