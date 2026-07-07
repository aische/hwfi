---
name: workflows/main
inputs:
  src: FileRef
outputs:
  content: String
imports:
  - builtin/read-file
  - builtin/write-file
  - workflows/sub
---

## flow

Mixes cacheable steps (read, sub-workflow call, a plain write) with one
non-cacheable step that reads the volatile `ctx.trace`. On resume the cacheable
steps are served from cache (no new events) while the volatile step re-executes
(§8.2, A7).

```step
c <- builtin/read-file(path = ${inputs.src})
s <- workflows/sub(note = ${c.text}) @sub
_ <- builtin/write-file(path = "cached.txt", text = ${s.marker}) @cached
_ <- builtin/write-file(path = "volatile.txt", text = "trace so far: ${ctx.trace}") @volatile
return { content = ${c.text} }
```
