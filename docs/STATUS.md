# Status

Last updated: 2026-07-10

## Current focus

**R1.11 tutorials** and **R1.12 release tag** (`0.1.0.0`). Author reference
manual at [workflow-reference.md](workflow-reference.md) — now covers agents
(`submit`), skills runtime, secrets, eval/trace builtins, and error posture.

## Done recently

- **Workflow reference expansion (2026-07-10):** `llm-agent-object` / `submit`,
  recoverable vs fatal agent errors, tool schema translation, skill discover/load
  limits, `eval-workflow`, cross-run trace, secrets/`ctx.env`, caching fixes,
  `examples/research` + `skills-runtime` patterns.
- **`builtin/json-values` (2026-07-10):** object/array → `List<Json>` for
  `foreach`; numeric key sort; null filtering. `examples/ship` `plan-tasks`
  bridge simplified.
- **ship hang fixes (2026-07-09):** planner forbids dev-server verify; build agent
  prefers build + `tools/vite-dev-smoke`; bidirectional `discover-skills` tag matching.

## Blockers

- None.

## Next up

[TASKS.md](TASKS.md) → R1.11 tutorials; R1.12 tag `0.1.0.0`.
