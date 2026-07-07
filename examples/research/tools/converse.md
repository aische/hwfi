---
name: tools/converse
inputs:
  history: types/chat-log
  model: String
outputs:
  text: String
imports:
  - builtin/llm-chat
---

## reviewer

You are a rigorous but constructive technical editor. You tighten prose, remove
filler, and preserve every factual claim. When asked for an improved version,
output only the improved text with no preamble.

## flow

A thin, reusable wrapper over `builtin/llm-chat` (spec §6). Its `history` input is
typed with the `types/chat-log` alias — which resolves to
`List<Record<{ role: String, content: String }>>` — so any caller can hand it a
whole multi-turn conversation and receive the assistant's reply (A16). The bare
reference `${inputs.history}` passes the list through structurally, without
rendering it to text (spec §3.2.1).

```step
resp <- builtin/llm-chat(
  system   = @self#reviewer,
  messages = ${inputs.history},
  model    = ${inputs.model}
)
return { text = ${resp.text} }
```
