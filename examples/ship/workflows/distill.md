---
name: workflows/distill
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
  - builtin/llm-generate
---

## writer

Distill a reusable hwfi declaration from a trace slice (Mode A, spec §6.6).

## flow

Optional post-run entrypoint: slice a successful implement/repair agent step and
write a draft skill under `skills/`.

```step
slice <- builtin/trace-slice(
  run_id = "${inputs.source_run}",
  qname = "${inputs.source_qname}",
  step_id = "${inputs.source_step_id}",
  include_nested = true
)
draft <- builtin/llm-generate(
  system = @self#writer,
  prompt = """Synthesize a ${inputs.kind} declaration named ${inputs.skill_name} from this trace slice.

Emit the full markdown source only — YAML frontmatter plus one ```step block.

Trace slice (JSON):
${slice.events}""",
  model = "smart"
) @write
_ <- builtin/write-file(path = "${inputs.target_path}", text = "${draft.text}") @persist
return {
  path = "${inputs.target_path}",
  note = "wrote skill draft — run hwfi check before calling it"
}
```
