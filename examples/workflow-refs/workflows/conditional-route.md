---
name: workflows/conditional-route
inputs:
  q: String
  use_search: Bool
outputs:
  text: String
imports:
  - tools/search
  - tools/lookup
---

## overview

Conditional dispatch without comparing ref values: branch on a flag and call
static qnames in each arm (§13.1.6).

```step
picked <- if ${inputs.use_search} {
  r <- tools/search(q = ${inputs.q}) @search
} else {
  r <- tools/lookup(q = ${inputs.q}) @lookup
} @pick
return { text = ${picked.text} }
```
