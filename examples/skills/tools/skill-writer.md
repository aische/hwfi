---
name: tools/skill-writer
inputs:
  slice: List<TraceEvent>
  kind: String
  name: String
outputs:
  text: String
imports:
  - builtin/llm-generate
---

## prompt

You are distilling a reusable hwfi declaration from an execution trace slice.

The author wants a **${inputs.kind}** named **${inputs.name}**.

Write a single markdown file body (YAML frontmatter + optional prose sections +
one ```step block) that:

1. Declares `name: ${inputs.name}` in frontmatter matching the requested kind.
2. Captures the procedure implied by the trace (tool calls, file edits, exec
   patterns) without embedding raw secrets.
3. Uses only agent-eligible builtins (no `builtin/introspect`).
4. Is minimal but runnable after `hwfi check`.

Trace slice (JSON):

${inputs.slice}

## flow

```step
r <- builtin/llm-generate(
  system = @self#prompt,
  prompt = "Emit the full markdown source for the skill file only — no commentary.",
  model = "smart"
)
return { text = ${r.text} }
```
