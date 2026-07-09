# `skills` — trace-derived declarations (Mode A)

Demonstrates **skill extraction** from prior runs (spec §6.6): a workflow slices
a bounded trace segment, asks a model to synthesize declaration markdown, and
writes it under `skills/` with `builtin/write-file`.

This is the recommended **Mode A** path: reuse existing agent loops, mutation
tools, and `hwfi check` for promotion — no parallel skill runtime.

## Layout

| Path | Role |
|------|------|
| `workflows/extract` | Entry workflow: `trace-slice` → `skill-writer` → `write-file` |
| `tools/skill-writer` | `llm-gen-object` step that turns a trace slice into markdown source |

## Prerequisites

1. A **prior successful run** in the target workspace (e.g. from
   `examples/coding` with `workflows/fix`).
2. Local **Ollama** with the catalog model pulled:

```bash
ollama pull mistral:latest   # catalog entry "smart"
```

## Extract a skill

```bash
mkdir -p /tmp/skills-ws
cp -r examples/coding/sample-workspace/* /tmp/skills-ws/

# Run the coding agent once to produce a trace worth distilling:
cabal run hwfi -- run examples/coding \
  --workspace /tmp/skills-ws \
  --entry workflows/fix \
  --input target=broken.sh

# Note the run id from output or:
cabal run hwfi -- show /tmp/skills-ws <run-id>

# Distill the agent step into a skill file:
cabal run hwfi -- run examples/skills \
  --workspace /tmp/skills-ws \
  --input source_run=<run-id> \
  --input source_qname=workflows/fix \
  --input source_step_id=fix \
  --input target_path=skills/fix-shell.md \
  --input skill_name=skills/fix-shell \
  --input kind=tool

# Validate the synthesized declaration:
cabal run hwfi -- check /tmp/skills-ws
```

Promotion is **explicit**: add `skills/fix-shell` to an agent `tools` list or
`imports:` on a workflow — there is no automatic registration.

## What this example does not cover

- **Mode B** (`builtin/extract-skill` stub writer) — optional task 9.4.4.
- **Automatic overwrite policy** — Mode A authors choose the target path; use
  version control to review drafts before committing.
