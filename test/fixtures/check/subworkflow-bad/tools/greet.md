---
name: tools/greet
inputs:
  name: String
outputs:
  greeting: String
---

## flow

```step
return { greeting = "Hi ${inputs.name}" }
```
