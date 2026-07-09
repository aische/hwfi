# Status

Last updated: 2026-07-09

## Current focus

**R1 v1.0.0 release prep.** Tutorial examples hardened with DeepSeek E2E tests;
tutorials (R1.11) and tag 0.1.0.0 remain.

## Done recently

- **R1.9 (2026-07-09):** `summarise` + `coding/fix` use DeepSeek
  (`deepseek-v4-flash`); `.env.example` per example; `ExamplesE2ESpec` live E2E
  on clean workspaces (pending without `DEEPSEEK_API_KEY`).
- **Spec sync (2026-07-09):** `spec.md` aligned with R1 — D3 cache semantics,
  `json-get`/`concat`/`log`, `workflow-log`, `hwfi cache clear`, §8.4 usage/cost,
  acceptance A27–A44; `spec-issues.md` / `h1-verification.md` D3 closed.
- **R1 P0/P1 (2026-07-09):** D3 agent cache fix; `docs/caching-and-resume.md`;
  `builtin/json-get`, `builtin/concat`, `builtin/log`; `hwfi cache clear`;
  root + `summarise` READMEs; `while` example (`tick-stop`); doc sync.

## Blockers

- None.

## Next up

[TASKS.md](TASKS.md) → R1.11 tutorials, R1.12 CHANGELOG + tag.
