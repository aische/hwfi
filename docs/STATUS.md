# Status

Last updated: 2026-07-10

## Current focus

**R1.11 tutorials** and **R1.12 release tag** (`0.1.0.0`). Author reference
manual at [workflow-reference.md](workflow-reference.md).

## Done recently

- **`builtin/json-values` (2026-07-10):** object/array → `List<Json>` for
  `foreach`; numeric key sort; null filtering. `examples/ship` `plan-tasks`
  bridge simplified; removed fixed eight-slot cap and null-skip in `main`.
- **Workflow author reference (2026-07-10):** [workflow-reference.md](workflow-reference.md)
  — project layout, step DSL, types, builtins, agents, control flow, skills,
  CLI, caching essentials.
- **ship hang fixes (2026-07-09):** planner forbids dev-server verify; build agent
  prefers build + `tools/vite-dev-smoke`; bidirectional `discover-skills` tag matching.
- **examples/ship reshape (2026-07-09):** prompt-only `spec` input, empty
  workspace, `plan` → `foreach build` → `review` → `audit`; skill library;
  `discover-skills` / `load-skill` in builder.

## Blockers

- None.

## Next up

[TASKS.md](TASKS.md) → R1.11 tutorials; R1.12 tag `0.1.0.0`.
