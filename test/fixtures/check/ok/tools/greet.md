---
name: tools/greet
inputs:
  name: String
outputs:
  greeting: String
---

## flow

Write a greeting file and return the greeting text.

```step
_       <- builtin/write-file(path = "greeting.txt", text = "Hi ${inputs.name}") @write
return { greeting = "Hi ${inputs.name}" }
```
