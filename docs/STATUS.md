# Status

Last updated: 2026-07-15

## Current focus

**Semantic review — experimental track (E4)** — E3 done; perf pass on semantic-check
workflows (list-unique-by, record-filter where, text-grep patterns). Next: graph
layer (`graph-*`, `graph-findings`). Plan: [semantic-check-design.md](semantic-check-design.md)
§Experimental track; checklist: [TASKS.md](TASKS.md).

**v2 runtime** — M6 done. **M5** (DB/server) deferred.

## Done recently

- **Semantic-check perf primitives** — `builtin/list-unique-by`; extended
  `record-filter` (dot paths, nested `where`); extended `text-grep` (`patterns` +
  `location` → `tags`). Rewired gate dedupe + speech-act layers.
- **Semantic report per run** — `semantic-check` writes
  `.hwfi/runs/<run-id>/semantic-report.json`.
- **E3 gated LLM pragmatics** — `review-gate`, `pragmatic-review`; report fields
  `mode`, `review_gate`, `pragmatic_findings`.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — **E4** graph findings (cycles, orphans, reachability).
