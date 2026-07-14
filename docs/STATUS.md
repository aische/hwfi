# Status

Last updated: 2026-07-14

## Current focus

**Semantic review example** — `examples/semantic-check` layers 0–1 complete with
`resolve-qnames-in-text` prose pass (no grep noise). Next Tier 3 graph builtins.

**v2 runtime (cursor + frames)** — M6 done. Design:
[execution-model.md](execution-model.md).

**M5** (DB / server `ProjectStore`) remains deferred — optional, not blocking
local filesystem mode.

## Done recently

- **`resolve-qnames-in-text` + prose layer rewrite** — engine builtin classifies
  qname mentions in markdown prose; `examples/semantic-check` scans `**/*.md`
  via `parse-markdown` + section scan; `list-concat` flattens nested findings.
  Ship report: `prose_hints` 142 → 2 (real README dead refs only).
- **Eval errors in `try`/`catch`** — catchable eval failures route through
  `handleStepError`; stack scan skips `FrSeq`/loop frames (§4.4.3).
- **`return` in control-flow blocks** — checker allows nested `return { … }`.
- **Semantic review Tier 2** — text metrics, similarity, corpus clustering.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — remaining Tier 3 graph builtins, layer 2+ review passes.
