# `semantic-check` — semantic review workflow (layers 0–1)

An ordinary hwfi workflow that reviews another project in its **workspace**.
Demonstrates the architecture from [semantic-check-design.md](../../docs/semantic-check-design.md):
review policy lives in the workflow; the engine exposes general-purpose builtins.

## What it does

Given a target project root in the workspace:

1. **Layer 0 — Structure:** `builtin/check-project` for parse/type errors and
   warnings; entrypoint coverage check against declared qnames.
2. **Layer 1 — Referential (interim):** `builtin/grep` over the workspace for
   qname-like tokens (`workflows/…`, `tools/…`, `builtin/…`, etc.) and emits
   **info** findings for manual review. Automated resolution will move to
   `resolve-qnames-in-text` when that builtin ships.

Writes `semantic-report.json` into the workspace.

No LLM calls — runs without API keys.

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

## Report shape

| Field | Content |
|-------|---------|
| `structural_errors` | Type/parse failures (layer 0) |
| `structural_warnings` | Checker warnings |
| `entry_findings` | Entrypoint not in declarations |
| `prose_hints` | Grep hits for qname-like lines (layer 1 interim) |

Each finding uses `types/finding`: severity, category, location, claim,
evidence, suggestion.

## Limitations (v0)

- No nested `foreach` in the step DSL yet, so step-metadata dead-ref checks
  (`bare_qnames`, static `agent_tools`) are deferred until
  `resolve-qnames-in-text` or nested loops land.
- Corpus quality (layer 2) and LLM pragmatics (layer 3) are not wired here.

## Related

- [semantic-check-design.md](../../docs/semantic-check-design.md)
- [workflow-reference.md](../../docs/workflow-reference.md) §13.1.8 builtins
