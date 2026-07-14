# Status

Last updated: 2026-07-15

## Current focus

**Semantic review — experimental track (E4)** — layer 3 gate policy tightened
(redundancy/divergence/dead-ref gates; entropy outliers excluded; trigger-bleed
post-filter). Next: graph layer (`graph-*`, `graph-findings`). Plan:
[semantic-check-design.md](semantic-check-design.md) §Experimental track;
checklist: [TASKS.md](TASKS.md).

**v2 runtime** — M6 done. **M5** (DB/server) deferred.

## Done recently

- **Layer 3 noise mitigation** — `review-gate` selects redundancy clusters,
  divergence pairs, coverage gaps, and dead references (not entropy outliers).
  Structured `review-gate-item` (`review_task`, peer body, priority). Rewritten
  pragmatic prompt + `pragmatic-filter-findings` trigger-bleed guard.
- **Semantic-check perf primitives** — `builtin/list-unique-by`; extended
  `record-filter` / `text-grep`. Rewired gate dedupe + speech-act layers.
- **Semantic report per run** — `.hwfi/runs/<run-id>/semantic-report.json`.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — **E4** graph findings (cycles, orphans, reachability).
