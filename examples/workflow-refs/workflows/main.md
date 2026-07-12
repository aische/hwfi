---
name: workflows/main
inputs:
  q: String
  use_search: Bool
outputs:
  text: String
  note: String
imports:
  - workflows/conditional-route
  - workflows/pass-handler
  - tools/search
---

## overview

Entry workflow for the workflow-refs example: conditional static dispatch and
passing a `WorkflowRef` input.

```step
routed <- workflows/conditional-route(
  q = ${inputs.q},
  use_search = ${inputs.use_search}
) @route
held <- workflows/pass-handler(
  handler = tools/search,
  q = ${inputs.q}
) @hold
return { text = ${routed.text}, note = ${held.note} }
```
