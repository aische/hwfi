# Status

Last updated: 2026-07-14

## Current focus

**Semantic review — experimental track (E4)** — E3 done: gated layer 3
`llm-gen-object` pragmatics (`review-gate`, `pragmatic-review`, `mode`
strict/exploratory, `pragmatic_findings`). Next: graph layer (`graph-*`,
`graph-findings`). Plan: [semantic-check-design.md](semantic-check-design.md)
§Experimental track; checklist: [TASKS.md](TASKS.md).

**v2 runtime** — M6 done. **M5** (DB/server) deferred.

## Done recently

- **E3 gated LLM pragmatics** — `review-gate`, `pragmatic-review`; report fields
  `mode`, `review_gate`, `pragmatic_findings`; `mode=exploratory` + schema input.
- **E2 speech-act heuristics** — scan/align; `speech_act_hints`; `split-text`,
  `text-grep`.
- **E1 layer 2 wiring** — corpus profile, clusters, hints in v1 report.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — **E4** graph findings (cycles, orphans, reachability).
