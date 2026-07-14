# Status

Last updated: 2026-07-14

## Current focus

**Semantic review — experimental track (E1)** — layers 0–1 and Tier 1–2 engine
primitives are done. Next: wire layer 2 corpus analysis into
`examples/semantic-check` (entropy + similarity as review signals), then E2
speech-act heuristics and gated layer 3 LLM. Plan:
[semantic-check-design.md](semantic-check-design.md) §Experimental track;
checklist: [TASKS.md](TASKS.md).

**v2 runtime** — M6 done. **M5** (DB/server) deferred.

## Done recently

- **Layers 0–1 + prose resolver** — `resolve-qnames-in-text` section scan;
  ship `prose_hints` 142 → 2.
- **Tier 2 builtins** — Shannon entropy, compression ratio, Jaccard/LCS,
  corpus clustering (`Hwfi.Text.Corpus`).
- **Semantic-check example** — `semantic-report/v0`; no LLM; runs without API keys.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — **E1** corpus profile/clusters/hints → report v1.
