# `semantic-pragmatic` — optional layer 3 LLM review

Runs bounded `llm-gen-object` pragmatics on `review_gate` items from a prior
[`semantic-check`](../semantic-check/README.md) run. Policy lives in this
workflow; the engine provides `read-json`, `llm-gen-object`, and list plumbing.

## What it does

1. Load `.hwfi/runs/<source_run>/semantic-report.json` from the workspace.
2. Read `review_gate` items (full slice bodies computed during check).
3. Run `llm-gen-object` on each gated slice (max 8, same gate policy as check).
4. Post-filter felicity findings and merge `pragmatic_findings` back into the
   report in the same run directory.

Findings may vary between runs — document in report metadata when summarizing.

## Prerequisites

- A completed `semantic-check` run with a non-empty `review_gate` (optional but
  typical for meaningful output).
- `model-catalog.json` + provider (default: local Ollama `llama3.2:latest` as
  catalog entry `fast`).
- Pass `--input schema=@examples/semantic-pragmatic/pragmatic-schema.json`.

## Running

```bash
cabal run hwfi -- check examples/semantic-pragmatic

cabal run hwfi -- run examples/semantic-pragmatic \
  --workspace examples/ship \
  --input source_run=<run-id> \
  --input schema=@examples/semantic-pragmatic/pragmatic-schema.json
```

`source_run` is the run id from `semantic-check` (directory under
`.hwfi/runs/`). The workflow updates `semantic-report.json` in place.

Then optionally summarize:

```bash
cabal run hwfi -- run examples/semantic-summary \
  --workspace examples/ship \
  --input source_run=<run-id> \
  --input mode=mechanical
```

Output JSON includes `report_path`.

## Pipeline position

```text
semantic-check       → semantic-report.json (+ review_gate)
  ↓
semantic-pragmatic   → adds pragmatic_findings to same report
  ↓ optional
semantic-summary     → semantic-summary.md
```

## Related

- [semantic-check](../semantic-check/README.md)
- [semantic-summary](../semantic-summary/README.md)
- [semantic-check-design.md](../../docs/semantic-check-design.md) §Gated pragmatics
