# Status

Last updated: 2026-07-14

## Current focus

**Semantic review (Tier 1 done)** — `builtin/check-project` and
`builtin/parse-markdown` implemented with tests. Next: example
`examples/semantic-check` workflow (layers 0–1), then Tier 2 builtins.

**v2 runtime (cursor + frames)** — M6 done. Design:
[execution-model.md](execution-model.md).

**M5** (DB / server `ProjectStore`) remains deferred — optional, not blocking
local filesystem mode.

## Done recently

- **Semantic review Tier 1** — `check-project` (parse + type-check + declaration
  metadata, call graph) and `parse-markdown` (frontmatter, sections, fences).
- **Merge-prep docs** — CHANGELOG `[Unreleased]` (0.2.0.0 breaking changes),
  upgrade guide in `caching-and-resume.md` / README.
- **Per-transition stepping** — `hwfi step` / `hwfi run --step`.
- **Resume robustness** — Single transition dispatch; checkpoint before agent I/O.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — `examples/semantic-check` workflow, Tier 2 builtins,
or v1.1 backlog.
