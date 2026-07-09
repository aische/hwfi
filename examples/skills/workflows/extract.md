---
name: workflows/extract
inputs:
  source_run: String
  source_qname: String
  source_step_id: String
  target_path: String
  skill_name: String
  kind: String
outputs:
  path: String
  note: String
imports:
  - builtin/trace-slice
  - builtin/write-file
  - tools/skill-writer
---

## overview

Mode A skill extraction (spec §6.6.3): slice a prior run, ask a model to
synthesize declaration markdown, and write it under `skills/`.

Typical use after a successful agent run (e.g. `examples/coding` →
`workflows/fix`):

```bash
cabal run hwfi -- run examples/skills \
  --workspace /tmp/skills-ws \
  --input source_run=<prior-run-id> \
  --input source_qname=workflows/fix \
  --input source_step_id=fix \
  --input target_path=skills/fix-shell.md \
  --input skill_name=skills/fix-shell \
  --input kind=tool
```

Then `hwfi check` the workspace and promote the skill via `imports:` or a
`ToolRef` on the next agent invocation.

## flow

```step
slice <- builtin/trace-slice(
  run_id = "${inputs.source_run}",
  qname = "${inputs.source_qname}",
  step_id = "${inputs.source_step_id}",
  include_nested = true
)
draft <- tools/skill-writer(
  slice = ${slice.events},
  kind = "${inputs.kind}",
  name = "${inputs.skill_name}"
) @write
_ <- builtin/write-file(path = "${inputs.target_path}", text = "${draft.text}") @persist
return {
  path = "${inputs.target_path}",
  note = "wrote skill draft — run hwfi check before calling it"
}
```
