---
name: workflows/main
inputs:
  path: FileRef
outputs:
  summary: String
imports:
  - builtin/read-file
  - builtin/llm-generate
  - tools/greet
---

## system

You are a concise summariser. Return one paragraph, no preamble.

## flow

Read the file and summarise it.

```step
contents <- builtin/read-file(path = ${inputs.path})
summary  <- builtin/llm-generate(
  system = @self#system,
  prompt = "Summarise the following:\n\n${contents.text}",
  model  = "gpt-5"
) @summary
return { summary = ${summary.text} }
```
