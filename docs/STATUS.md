# Status

Last updated: 2026-07-14

## Current focus

**Semantic review — experimental track (E2)** — E1 done: layer 2 corpus profile,
clusters, and hints wired into `semantic-report/v1`. Next: speech-act heuristics
(`speech-act-scan`, `speech-act-align`) and gated layer 3 LLM. Plan:
[semantic-check-design.md](semantic-check-design.md) §Experimental track;
checklist: [TASKS.md](TASKS.md).

**v2 runtime** — M6 done. **M5** (DB/server) deferred.

## Done recently

- **E1 layer 2 wiring** — `corpus-profile`, `corpus-clusters`, `corpus-hints`;
  report schema `semantic-report/v1` with `corpus_profile` + `corpus_hints`.
- **Layers 0–1 + prose resolver** — `resolve-qnames-in-text` section scan;
  ship `prose_hints` 142 → 2.
- **Tier 2 builtins** — Shannon entropy, compression ratio, Jaccard/LCS,
  corpus clustering (`Hwfi.Text.Corpus`).

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — **E2** speech-act scan/align → `speech_act_hints`.
