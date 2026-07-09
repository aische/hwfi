# Status

Last updated: 2026-07-09

## Current focus

**9.2 `builtin/eval-workflow` complete (A34/A35).** Optional items next: 9.1,
9.3–9.6; author backlog 9.9–9.14 (spec §13.1).

## Done recently

- **9.2 eval-workflow (2026-07-09):** `builtin/eval-workflow` (§6.4) — parse,
  type-check, and run dynamic workflow source; `{ ok, outputs, errors }` on
  recoverable failure; non-cacheable; agent-eligible. Tests A34/A35 in
  `EvalWorkflowSpec`. 249 tests green.
- **A32 while + llm-agent resume (2026-07-09):** Integration test in
  `ControlFlowSpec` — predicate sub-workflow uses `builtin/llm-agent`;
  resume replays pinned decisions without new `LlmCall`/`while-pred` events.
  245 tests green.
- **§6.4 eval-workflow spec (2026-07-09):** Dynamic workflow evaluation
  specified — `{ ok, outputs, errors }` result; parse/check failures
  non-fatal; recoverable in agent loop (A34/A35).
- **8.g agent checkpoint (2026-07-09):** Persist agent-loop `messages` +
  `next_round` under the agent step-key on each completed round; reload on
  resume to skip re-walking earlier rounds (§8.2.1 perf optimization).
  Cleared on successful termination. Test in `AgentSpec`.

## Blockers

- None.

## Next up

[TASKS.md](TASKS.md) → optional 9.1, 9.3–9.6, 9.9–9.14.
