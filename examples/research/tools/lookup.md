---
name: tools/lookup
inputs:
  name: String
outputs:
  text: String
imports:
  - builtin/read-file
---

## flow

A read-only tool the agent can call to fetch one document's contents by name.
The model supplies `name`; the tool builds the workspace path itself, so a call
can only ever read from the `docs/` corpus (spec §7.1). Returns the file text as
a plain `String` — an agent-eligible output the model can reason over.

```step
doc <- builtin/read-file(path = "docs/${inputs.name}")
return { text = ${doc.text} }
```
