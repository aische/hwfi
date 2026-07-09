# Status

Last updated: 2026-07-09

## Current focus

**Task 9.15 (agent skill runtime) is implemented.** Next: R1.11 tutorials and
R1.12 release tag. Optional follow-up: `examples/skills-runtime` E2E in CI.

## Done recently

- **Spec sync (2026-07-09):** `spec.md` §6.7 / §6.1.6 marked implemented;
  A45–A50 acceptance; §14 skill-runtime polish; `spec-issues`, `TASKS`,
  `README` aligned.
- **9.15 Skill runtime (2026-07-09):** `SkillCatalog` + `kind` frontmatter;
  `builtin/discover-skills` / `builtin/load-skill`; agent mid-loop instruction
  injection and callable expansion; extended checkpoint/resume; per-round tools
  fingerprint; checker relaxation + warnings for dynamic `tools` lists;
  `examples/skills-runtime`; tests A45–A50.
- **§6.7 skill runtime spec (2026-07-09):** Option C design in `spec.md` /
  `skills-design.md`.
- **examples/ship (2026-07-09):** Capstone coding-agent pipeline.

## Blockers

- None.

## Next up

[TASKS.md](TASKS.md) → R1.11 tutorials; R1.12 tag `0.1.0.0`.
