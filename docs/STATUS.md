# Status

Last updated: 2026-07-08

## Current focus

**§8.4 usage/cost accounting shipped** (TASKS 9.8). Per-call `cost_usd` on
`llm-call`; running total in `run.json` and `ctx.run.usage`; optional
`project.json` `budget.max_cost_usd`; cached/resumed provider calls bill $0;
`hwfi show` usage summary. 231 tests green.

## Done recently

- **9.8:** `Hwfi.Runtime.{RunUsage,Usage}`; billing in one-shot LLM builtins +
  agent model rounds; budget gate; volatile `ctx.run.usage` in checker/executor;
  tests A27–A29 + `UsageSpec`.
- **H1** runtime hardening complete (2026-07-08).
- **M8** control flow complete (2026-07-08).

## Blockers

- None.

## Next up

[TASKS.md](TASKS.md) → optional items (8.g, 9.1–9.7).
