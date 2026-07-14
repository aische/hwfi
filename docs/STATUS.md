# Status

Last updated: 2026-07-14

## Current focus

**Semantic review (Tier 2 done)** — `text-metrics`, `text-similarity`, and
`text-search-corpus` implemented with tests. Next: `examples/semantic-check`
workflow (layers 0–1), then Tier 3 graph/reference builtins.

**v2 runtime (cursor + frames)** — M6 done. Design:
[execution-model.md](execution-model.md).

**M5** (DB / server `ProjectStore`) remains deferred — optional, not blocking
local filesystem mode.

## Done recently

- **Semantic review Tier 2** — entropy/compression metrics, Jaccard/LCS
  similarity, corpus overlap clustering.
- **Semantic review Tier 1** — `check-project`, `parse-markdown`.
- **Merge-prep docs** — CHANGELOG `[Unreleased]` (0.2.0.0 breaking changes),
  upgrade guide in `caching-and-resume.md` / README.
- **Per-transition stepping** — `hwfi step` / `hwfi run --step`.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — `examples/semantic-check` workflow, Tier 3 builtins,
or v1.1 backlog.
