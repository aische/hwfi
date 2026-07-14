# `semantic-check` — semantic review workflow (layers 0–3)

An ordinary hwfi workflow that reviews another project in its **workspace**.
Demonstrates the architecture from [semantic-check-design.md](../../docs/semantic-check-design.md):
review policy lives in the workflow; the engine exposes general-purpose builtins.

## What it does

Given a target project root in the workspace:

1. **Layer 0 — Structure:** `builtin/check-project` for parse/type errors and
   warnings; entrypoint coverage check against declared qnames.
2. **Layer 1 — Referential:** nested `foreach` over declaration step metadata
   (`bare_qnames`, static `agent_tools`) resolved against the project catalog
   plus shipped builtins; prose scan via `resolve-qnames-in-text` on markdown
   sections (skips ` ```step ` fences and shipped builtins).
3. **Layer 2 — Corpus:** `parse-markdown` section bodies → `text-metrics` per
   slice; `text-search-corpus` clusters; entropy/compression outlier and
   redundancy hints (signals, not verdicts).
4. **Layer 2b — Speech acts:** `split-text` + `text-grep` tag illocutionary
   force per sentence; align `llm-agent` tool lists to agent-section directives;
   emit `speech_act_hints` (bare directives, coverage gaps, declarative role cues).
5. **Layer 3 — Pragmatics (optional):** when `mode=exploratory`, union gate
   signals from layers 2 / 2b → bounded `llm-gen-object` review per slice.

Writes `semantic-report.json` into the workspace (`semantic-report/v1`).

**Strict mode** (default) runs without API keys. **Exploratory mode** requires a
model catalog and provider (see below).

## Roadmap (experimental track)

See [TASKS.md](../../docs/TASKS.md) and design doc §Experimental track.

| Phase | Adds |
|-------|------|
| **E1** | Layer 2 corpus profile, clusters, hints *(done)* |
| **E2** | Speech-act pattern tagger + step↔agent alignment *(done)* |
| **E3** | Gated `llm-gen-object` pragmatics (`mode=exploratory`) *(done)* |
| **E4** | Graph findings (cycles, orphans, reachability) |

## Prerequisites

- **Strict:** none.
- **Exploratory:** `model-catalog.json` + provider (default: local Ollama
  `llama3.2:latest` as catalog entry `fast`). Pass
  `--input schema=@examples/semantic-check/pragmatic-schema.json`.

## Running

Point the workspace at the project you want reviewed. The checker loads from
`examples/semantic-check`; artifacts land in the workspace.

```bash
cabal run hwfi -- check examples/semantic-check

# Strict (no LLM) — default for CI
cabal run hwfi -- run examples/semantic-check \
  --workspace examples/hello \
  --input path=. \
  --input entry=workflows/main \
  --input mode=strict \
  --input schema=null

# Exploratory (gated LLM on flagged slices, max 8)
cabal run hwfi -- run examples/semantic-check \
  --workspace examples/hello \
  --input path=. \
  --input entry=workflows/main \
  --input mode=exploratory \
  --input schema=@examples/semantic-check/pragmatic-schema.json
```

Review a project with a type error:

```bash
cabal run hwfi -- run examples/semantic-check \
  --workspace test/fixtures/check/type-mismatch \
  --input path=. \
  --input entry=workflows/main \
  --input mode=strict \
  --input schema=null
```

On success the workflow prints `{ "report_path": "semantic-report.json", "ok": … }`
and the workspace contains `semantic-report.json`.

## Report shape (v1)

| Field | Content |
|-------|---------|
| `mode` | `strict` or `exploratory` |
| `review_gate` | Slice ids selected for layer 3 (exploratory only) |
| `structural_errors` | Type/parse failures (layer 0) |
| `structural_warnings` | Checker warnings |
| `entry_findings` | Entrypoint not in declarations |
| `prose_hints` | Unresolved qname mentions in markdown prose (layer 1) |
| `step_referential` | Nested per-decl/per-step referential scan (`bare` / `agent` matrices) |
| `corpus_profile` | Per-section metrics rows (layer 2; not findings) |
| `corpus_hints` | Entropy/compression outliers, similarity clusters (layer 2) |
| `speech_act_hints` | Illocutionary alignment hints (layer 2b) |
| `pragmatic_findings` | LLM judgments (exploratory mode only; may vary between runs) |

Each finding uses `types/finding`: severity, category, location, claim,
evidence, suggestion.

## Nested `foreach`

Layer 1 uses nested loops (`decl → step → mention`) in
`tools/step-ref-findings` and `tools/referential-scan`. Inner loops must bind
their result (`inner <- foreach …`), not appear as bare statements — see
[workflow-reference.md](../../docs/workflow-reference.md).

## Related

- [semantic-check-design.md](../../docs/semantic-check-design.md)
- [workflow-reference.md](../../docs/workflow-reference.md) §13.1.8 builtins
