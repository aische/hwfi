# `semantic-check` — deterministic semantic review (layers 0–2b)

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

Always computes **`review_gate`** — bounded slice items for optional LLM review
via [`semantic-pragmatic`](../semantic-pragmatic/README.md).

Writes `.hwfi/runs/<run-id>/semantic-report.json` in the workspace
(`semantic-report/v1`). Each run keeps its own report alongside `trace.jsonl`.

Runs without API keys.

## Pipeline

```text
semantic-check       → semantic-report.json (+ review_gate always)
  ↓ optional
semantic-pragmatic   → merges pragmatic_findings into same run dir
  ↓ optional
semantic-summary     → semantic-summary.md
```

## Roadmap

See [TASKS.md](../../docs/TASKS.md) and design doc §Architecture cleanup.

| Phase | Adds | Status |
|-------|------|--------|
| **E1–E3** | Corpus, speech acts, gated LLM (now in semantic-pragmatic) | done |
| **Summary** | `semantic-summary` markdown digest | done |
| **AC** | Split check / pragmatic / summary | **done** |
| **E4** | Graph findings (cycles, orphans, reachability) | next |

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

On success the workflow prints
`{ "report_path": ".hwfi/runs/<run-id>/semantic-report.json", "ok": … }`.

Optional pragmatic LLM pass and markdown summary:

```bash
# After check — requires model catalog (see semantic-pragmatic README)
cabal run hwfi -- run examples/semantic-pragmatic \
  --workspace examples/hello \
  --input source_run=<run-id> \
  --input schema=@examples/semantic-pragmatic/pragmatic-schema.json

cabal run hwfi -- run examples/semantic-summary \
  --workspace examples/hello \
  --input source_run=<run-id> \
  --input mode=mechanical
```

## Report shape (v1)

| Field | Content |
|-------|---------|
| `mode` | Always `deterministic` for check runs |
| `review_gate` | High-signal gate items (objects with slice bodies; max 8) |
| `structural_errors` | Type/parse failures (layer 0) |
| `structural_warnings` | Checker warnings |
| `entry_findings` | Entrypoint not in declarations |
| `prose_hints` | Unresolved qname mentions in markdown prose (layer 1) |
| `step_referential` | Nested per-decl/per-step referential scan |
| `corpus_profile` | Per-section metrics rows (layer 2; not findings) |
| `corpus_hints` | Entropy/compression outliers, similarity clusters (layer 2) |
| `speech_act_hints` | Illocutionary alignment hints (layer 2b) |
| `pragmatic_findings` | Added by `semantic-pragmatic` when run (optional) |

Each finding uses `types/finding`: severity, category, location, claim,
evidence, suggestion.

## Related

- [semantic-pragmatic](../semantic-pragmatic/README.md) — optional layer 3 LLM
- [semantic-summary](../semantic-summary/README.md) — markdown digest
- [semantic-check-design.md](../../docs/semantic-check-design.md)
