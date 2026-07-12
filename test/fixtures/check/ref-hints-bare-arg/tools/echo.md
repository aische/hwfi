---
name: tools/echo
inputs:
  text: String
outputs:
  text: String
---

```step
return { text = ${inputs.text} }
```
