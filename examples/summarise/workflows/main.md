---
name: workflows/main
inputs:
  path: FileRef
  out: FileRef
outputs:
  summary: String
imports:
  - builtin/read-file
  - builtin/write-file
  - builtin/llm-generate
---

## system

You are a concise summariser. Return a single paragraph, no preamble, no
bullet points. Capture the essential point of the text and nothing else.

## flow

Read the input file, summarise its contents with the model, and write the
summary to the output file. Exercises the two-step `read-file` → `llm-generate`
pipeline (A3) and the `@self#system` prompt reference (A9).

```step
contents <- builtin/read-file(path = ${inputs.path})
summary  <- builtin/llm-generate(
  system = @self#system,
  prompt = "Summarise the following text:\n\n${contents.text}",
  model  = "default"
) @summarise
_        <- builtin/write-file(path = ${inputs.out}, text = ${summary.text}) @write
return { summary = ${summary.text} }
```
