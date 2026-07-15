# Status

Last updated: 2026-07-15

## Current focus

**Semantic review** — `semantic-summary` now takes `source_run` only (paths derived
from run id). Next engine track: **E4** graph layer (`graph-*`, `graph-findings`).
Plan: [semantic-check-design.md](semantic-check-design.md); checklist: [TASKS.md](TASKS.md).

**v2 runtime** — M6 done. **M5** (DB/server) deferred.

## Done recently

- **`semantic-summary` CLI** — `--input source_run=<run-id>`; added `builtin/read-json`.
- **`semantic-summary` workflow** — mechanical + optional narrative digest.
- **Layer 3 noise mitigation** — high-signal review gates; pragmatic post-filter.
- **Semantic report per run** — `.hwfi/runs/<run-id>/semantic-report.json`.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — **E4** graph findings; optional narrative summary tuning.
