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

Run `semantic-check` first, then summarize using the same workspace and run id:

```bash
cabal run hwfi -- check examples/semantic-summary

# Mechanical (no LLM)
cabal run hwfi -- run examples/semantic-summary \
  --workspace examples/ship \
  --input report=@.hwfi/runs/<run-id>/semantic-report.json \
  --input mode=mechanical \
  --input out=.hwfi/runs/<run-id>/semantic-summary.md

# Narrative (LLM synthesis)
cabal run hwfi -- run examples/semantic-summary \
  --workspace examples/ship \
  --input report=@.hwfi/runs/<run-id>/semantic-report.json \
  --input mode=narrative \
  --input out=.hwfi/runs/<run-id>/semantic-summary.md
```

Output JSON includes `summary_path` and `summary_text`.

## Modes

| `mode` | API keys | Output |
|--------|----------|--------|
| `mechanical` | No | Deterministic markdown rollup |
| `narrative` | Yes | LLM-prioritized digest from mechanical text |

Note: `semantic-check` layer 3 uses `mode=exploratory` (not `explanatory`).

## Related

- [semantic-check](../semantic-check/README.md)
- [semantic-check-design.md](../../docs/semantic-check-design.md)
