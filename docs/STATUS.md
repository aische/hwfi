# Status

Last updated: 2026-07-15

## Current focus

**Semantic review** — `examples/semantic-summary` added (mechanical + optional
narrative digest). Next engine track: **E4** graph layer (`graph-*`,
`graph-findings`). Plan: [semantic-check-design.md](semantic-check-design.md);
checklist: [TASKS.md](TASKS.md).

**v2 runtime** — M6 done. **M5** (DB/server) deferred.

## Done recently

- **`semantic-summary` workflow** — rolls up `semantic-report.json` to markdown;
  `mode=mechanical` (no keys) or `mode=narrative` (LLM synthesis).
- **Layer 3 noise mitigation** — high-signal review gates; pragmatic post-filter.
- **Semantic report per run** — `.hwfi/runs/<run-id>/semantic-report.json`.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — **E4** graph findings; optional narrative summary tuning.
