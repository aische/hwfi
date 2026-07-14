# Status

Last updated: 2026-07-14

## Current focus

**Semantic review — experimental track (E3)** — E2 done: deterministic speech-act
scan/align wired into `semantic-report/v1` (`speech_act_hints`). Engine gained
`split-text` and `text-grep` (sentence tagging primitives). Next: gated layer 3
LLM (`review-gate`, `pragmatic-review`). Plan:
[semantic-check-design.md](semantic-check-design.md) §Experimental track;
checklist: [TASKS.md](TASKS.md).

**v2 runtime** — M6 done. **M5** (DB/server) deferred.

## Done recently

- **E2 speech-act heuristics** — `speech-act-scan`, `speech-act-align`;
  `types/speech-act-tag`, `types/speech-act-hint`; report field
  `speech_act_hints`; builtins `split-text`, `text-grep`.
- **E1 layer 2 wiring** — corpus profile, clusters, hints in v1 report.
- **Layers 0–1 + prose resolver** — ship `prose_hints` 142 → 2.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — **E3** gated LLM pragmatics (`mode=exploratory`).
