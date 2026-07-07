---
name: workflows/main
inputs:
  path: FileRef
  name: String
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

Greet the user, read the file, and summarise it.

```step
greeting <- tools/greet(name = ${inputs.name})
contents <- builtin/read-file(path = ${inputs.path})
summary  <- builtin/llm-generate(
  system = @self#system,
  prompt = "Summary for ${greeting.greeting} (${ctx.env.USER_NAME}):\n\n${contents.text}",
  model  = "llama_3_2"
) @summary
return { summary = ${summary.text} }
```
