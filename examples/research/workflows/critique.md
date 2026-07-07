---
name: workflows/critique
inputs:
  draft: String
  topic: String
outputs:
  refined: String
imports:
  - tools/converse
---

## flow

Improve a draft summary through a short, scripted multi-turn conversation. The
`messages` list is a literal `List<Record<{ role, content }>>` (assignable to the
`types/chat-log` alias on `tools/converse`), built with record and list literals
and string interpolation. Execution is delegated to the reusable `tools/converse`
tool, so the enclosing sub-workflow call (A6) nests the underlying `llm-chat`
events (A16) inside this step in the trace (spec §8.3.3.6).

```step
-- A three-turn exchange: present the draft, acknowledge, then ask for a
-- tightened rewrite. Roles are validated at runtime by builtin/llm-chat.
out <- tools/converse(
  model   = "smart",
  history = [
    { role = "user",      content = "Here is a draft summary about ${inputs.topic}:\n\n${inputs.draft}" },
    { role = "assistant", content = "Understood. I will review it for accuracy and concision." },
    { role = "user",      content = "Now return an improved, tighter version. Output only the summary." }
  ]
)
return { refined = ${out.text} }
```
