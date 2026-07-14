# `semantic-check` — semantic review workflow (layers 0–2)

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

Writes `semantic-report.json` into the workspace (`semantic-report/v1`).

No LLM calls — runs without API keys.

## Roadmap (experimental track)

See [TASKS.md](../../docs/TASKS.md) and design doc §Experimental track.

| Phase | Adds |
|-------|------|
| **E1** | Layer 2 corpus profile, clusters, hints *(done)* |
| **E2** | Speech-act pattern tagger + step↔agent alignment *(done)* |
| **E3** | Gated `llm-gen-object` pragmatics (`mode=exploratory`) |
| **E4** | Graph findings (cycles, orphans, reachability) |

## Prerequisites

None.

## Running

Point the workspace at the project you want reviewed. The checker loads from
`examples/semantic-check`; artifacts land in the workspace.

```bash
cabal run hwfi -- check examples/semantic-check

cabal run hwfi -- run examples/semantic-check \
  --workspace examples/hello \
  --input path=. \
  --input entry=workflows/main
```

Review a project with a type error:

```bash
cabal run hwfi -- run examples/semantic-check \
  --workspace test/fixtures/check/type-mismatch \
  --input path=. \
  --input entry=workflows/main
```

On success the workflow prints `{ "report_path": "semantic-report.json", "ok": … }`
and the workspace contains `semantic-report.json`.

## Report shape (v1)

| Field | Content |
|-------|---------|
| `structural_errors` | Type/parse failures (layer 0) |
| `structural_warnings` | Checker warnings |
| `entry_findings` | Entrypoint not in declarations |
| `prose_hints` | Unresolved qname mentions in markdown prose (layer 1) |
| `step_referential` | Nested per-decl/per-step referential scan (`bare` / `agent` matrices) |
| `corpus_profile` | Per-section metrics rows (layer 2; not findings) |
| `corpus_hints` | Entropy/compression outliers, similarity clusters (layer 2) |
| `speech_act_hints` | Illocutionary alignment hints (layer 2b) |

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
