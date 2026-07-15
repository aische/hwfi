# `semantic-summary` — digest a semantic report

Post-processes `semantic-report.json` from [`semantic-check`](../semantic-check)
into a short markdown summary. Policy lives in this workflow; the engine
provides `json-get`, `json-values`, `concat`, and optional `llm-generate`.

## What it does

1. **Collect** actionable findings (`error` and `warning`) from report fields:
   structural, entry, prose, corpus (warnings only), pragmatic.
2. **Omit** info-level corpus metric hints and speech-act info hints (still in
   the full JSON report).
3. **Render** markdown (`# Semantic review summary` + bullet findings).
4. **Optional narrative** (`mode=narrative`): LLM synthesis over the mechanical
   digest.

## Prerequisites

- **Mechanical:** none.
- **Narrative:** `model-catalog.json` + provider (default: local Ollama
  `llama3.2:latest` as catalog entry `fast`).

## Running

Run the pipeline in order:

```bash
# 1. Deterministic check (no API keys)
cabal run hwfi -- run examples/semantic-check \
  --workspace examples/ship \
  --input path=. \
  --input entry=workflows/main

# 2. Optional pragmatic LLM pass
cabal run hwfi -- run examples/semantic-pragmatic \
  --workspace examples/ship \
  --input source_run=<run-id> \
  --input schema=@examples/semantic-pragmatic/pragmatic-schema.json

# 3. Markdown digest
cabal run hwfi -- run examples/semantic-summary \
  --workspace examples/ship \
  --input source_run=<run-id> \
  --input mode=mechanical
```

`source_run` is the run id from `semantic-check` (the directory under
`.hwfi/runs/` that contains `semantic-report.json`). The summary is written to
`.hwfi/runs/<source_run>/semantic-summary.md` alongside the report.

**Tip:** for a human-readable digest without pragmatic noise, summarize after
check only (skip step 2). Pragmatic runs add `pragmatic_findings` to the rollup.

Output JSON includes `summary_path` and `summary_text`.

## Modes

| `mode` | API keys | Output |
|--------|----------|--------|
| `mechanical` | No | Deterministic markdown rollup |
| `narrative` | Yes | LLM-prioritized digest from mechanical text |

## Related

- [semantic-check](../semantic-check/README.md)
- [semantic-pragmatic](../semantic-pragmatic/README.md)
- [semantic-check-design.md](../../docs/semantic-check-design.md)
