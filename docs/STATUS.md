# Status

Last updated: 2026-07-15

## Current focus

**E4 graph layer** — `graph-*` builtins and `graph_findings` in check. Design:
[semantic-check-design.md](semantic-check-design.md) §Experimental track;
checklist: [TASKS.md](TASKS.md).

**v2 runtime** — M6 done. **M5** (DB/server) deferred.

## Done recently

- **Architecture cleanup** — `semantic-check` is always deterministic (layers
  0–2b); always emits full `review_gate` items; new `semantic-pragmatic`
  workflow for optional layer 3 LLM; pipeline docs updated.
- **Semantic review track (E1–E3 + summary)** — layers 0–3 split across check
  and pragmatic; `semantic-summary` with `source_run` input.
- **Per-run reports** — `.hwfi/runs/<run-id>/semantic-report.json`.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — E4 graph findings.
