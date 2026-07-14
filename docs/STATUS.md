# Status

Last updated: 2026-07-14

## Current focus

**Semantic review example** — `examples/semantic-check` workflow (layers 0–1)
ships. Next: Tier 3 graph/reference builtins (`resolve-qnames-in-text` first).

**v2 runtime (cursor + frames)** — M6 done. Design:
[execution-model.md](execution-model.md).

**M5** (DB / server `ProjectStore`) remains deferred — optional, not blocking
local filesystem mode.

## Done recently

- **Semantic review example** — `examples/semantic-check`: layer 0
  (`check-project`, entrypoint coverage) + layer 1 interim (`grep` prose hints).
- **Semantic review Tier 2** — entropy/compression metrics, Jaccard/LCS
  similarity, corpus overlap clustering.
- **Semantic review Tier 1** — `check-project`, `parse-markdown`.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — Tier 3 builtins, layer 2+ review passes, or v1.1 backlog.
