---
name: workflows/main
inputs:
  q: String
outputs:
  text: String
imports:
  - tools/search
  - tools/echo
---

```step
r <- tools/echo(text = tools/search) @bad
return { text = ${r.text} }
```
