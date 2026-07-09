# Status

Last updated: 2026-07-09

## Current focus

**`examples/ship` reshaped** into a universal prompt-only coding agent. Next:
R1.11 tutorials and R1.12 release tag.

## Done recently

- **ship hang fixes (2026-07-09):** planner forbids dev-server verify; build agent
  prefers build + `tools/vite-dev-smoke`; skip null task slots in `main`; bidirectional
  `discover-skills` tag matching (`SkillCatalog.textHits` / `tagHits`).
- **examples/ship reshape (2026-07-09):** prompt-only `spec` input, empty
  workspace, `plan` → `foreach build` → `review` → `audit`; skill library
  (TypeScript/Vite, Haskell/Cabal, React, HTML guides + `run-verify`);
  `discover-skills` / `load-skill` in builder; removed repair-demo artifacts.
- **9.15 Skill runtime (2026-07-09):** catalog, discover/load, checkpoint/resume;
  `examples/skills-runtime`; tests A45–A50.
- **Spec sync (2026-07-09):** §6.7 / §6.1.6 marked implemented.

## Blockers

- None.

## Next up

[TASKS.md](TASKS.md) → R1.11 tutorials; R1.12 tag `0.1.0.0`.
