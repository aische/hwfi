---
name: workflows/main
outputs:
  text: String
---

## flow

```step
c <- builtin/llm-generate(system = "s", prompt = "p", model = 42)
return { text = ${c.text} }
```
