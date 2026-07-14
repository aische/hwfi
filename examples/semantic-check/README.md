# `semantic-check` — semantic review workflow (layers 0–1)

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

Writes `semantic-report.json` into the workspace (`semantic-report/v0`).

No LLM calls — runs without API keys.

## Roadmap (experimental track)

See [TASKS.md](../../docs/TASKS.md) and design doc §Experimental track.

| Phase | Adds |
|-------|------|
| **E1** | Layer 2 corpus profile, clusters, hints (entropy + similarity) |
| **E2** | Speech-act pattern tagger + step↔agent alignment |
| **E3** | Gated `llm-gen-object` pragmatics (`mode=exploratory`) |
| **E4** | Graph findings (cycles, orphans, reachability) |

Target report schema: `semantic-report/v1` after E1–E2.

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

## Report shape (v0)

| Field | Content |
|-------|---------|
| `structural_errors` | Type/parse failures (layer 0) |
| `structural_warnings` | Checker warnings |
| `entry_findings` | Entrypoint not in declarations |
| `prose_hints` | Unresolved qname mentions in markdown prose (layer 1) |
| `step_referential` | Nested per-decl/per-step referential scan (`bare` / `agent` matrices) |

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
