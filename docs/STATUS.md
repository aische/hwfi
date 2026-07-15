# Status

Last updated: 2026-07-15

## Current focus

**Architecture cleanup** — split deterministic semantic review from optional LLM
passes. `semantic-check` should always emit `review_gate`; layer 3 pragmatics
moves to a separate workflow. Plan: [semantic-check-design.md](semantic-check-design.md)
§Architecture cleanup; checklist: [TASKS.md](TASKS.md).

**v2 runtime** — M6 done. **M5** (DB/server) deferred.

## Done recently

- **Semantic review track (E1–E3 + summary)** — layers 0–3 in `semantic-check`;
  `semantic-summary` with `source_run` input and `builtin/read-json`.
- **Layer 3 noise mitigation** — high-signal review gates; pragmatic post-filter.
- **Per-run reports** — `.hwfi/runs/<run-id>/semantic-report.json`.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — architecture cleanup, then **E4** graph findings.
