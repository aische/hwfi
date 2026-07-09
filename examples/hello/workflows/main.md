---
name: workflows/main
inputs:
  path: FileRef
  out: FileRef
outputs:
  greeting: String
imports:
  - builtin/read-file
  - builtin/write-file
  - builtin/concat
  - workflows/inner
---

## banner

Hello from hwfi.

## flow

Read the input file, prepend a banner, call a sub-workflow, and write the
result. No LLM calls — runs without API keys.

```step
c      <- builtin/read-file(path = ${inputs.path})
merged <- builtin/concat(parts = [@self#banner, "\n", ${c.text}]) @merge
_      <- workflows/inner(note = ${c.text}) @inner
_      <- builtin/write-file(path = ${inputs.out}, text = ${merged.text}) @write
_      <- builtin/write-file(path = "banner.txt", text = @self#banner) @banner
return { greeting = ${merged.text} }
```
