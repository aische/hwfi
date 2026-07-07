---
name: workflows/answer
inputs:
  question: String
  schema: Json
outputs:
  value: Json
  rounds: Int
imports:
  - builtin/llm-agent-object
  - tools/corpus
  - tools/lookup
---

## agent

You are a research agent with access to a small document corpus. Use
`tools_corpus` to list documents and `tools_lookup` to read one. When you have
gathered enough evidence, call the `submit` tool exactly once — and never
alongside any other tool call — with your final structured result conforming to
the requested schema.

## flow

The typed-output variant (spec §6.1.3). `builtin/llm-agent-object` advertises the
same read-only tools plus a synthetic `submit` tool whose parameters are the
caller-supplied JSON `schema`. The loop terminates only when the model calls
`submit` on its own; its arguments become the step's `value` (a `Json` conforming
to `schema`). A `submit` mixed with other calls, or one that fails schema
validation, is fed back as a recoverable error so the model can retry (§6.1.4).

```step
result <- builtin/llm-agent-object(
  system = @self#agent,
  prompt = ${inputs.question},
  model = "smart",
  tools = [ tools/corpus, tools/lookup ],
  schema = ${inputs.schema},
  max_rounds = 6
) @answer
return { value = ${result.value}, rounds = ${result.rounds} }
```
