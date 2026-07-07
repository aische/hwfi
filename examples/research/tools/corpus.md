---
name: tools/corpus
inputs:
  dir: String
outputs:
  entries: List<String>
imports:
  - builtin/list-dir
---

## flow

A read-only tool the agent can call to discover which documents exist. Its only
input is an agent-eligible `String` (spec §6.1.1), and it reaches no privileged
builtin, so `builtin/llm-agent` may advertise it (spec §6.1.5). The directory is
resolved inside the sandbox (spec §7.1); the model never sees a raw path it did
not choose.

```step
listing <- builtin/list-dir(path = ${inputs.dir})
return { entries = ${listing.entries} }
```
