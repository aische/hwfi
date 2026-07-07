---
name: workflows/main
inputs:
  src: FileRef
  dst: FileRef
outputs:
  content: String
imports:
  - builtin/read-file
  - builtin/write-file
  - workflows/inner
---

## banner

HELLO FROM SELF

## flow

Read the source file, hand its text to a sub-workflow, copy it to the
destination, and write the `@self#banner` content out. Uses no LLM so it runs
without network access.

```step
c <- builtin/read-file(path = ${inputs.src})
_ <- workflows/inner(note = ${c.text}) @inner
_ <- builtin/write-file(path = ${inputs.dst}, text = ${c.text}) @copy
_ <- builtin/write-file(path = "banner.txt", text = @self#banner) @banner
return { content = ${c.text} }
```
