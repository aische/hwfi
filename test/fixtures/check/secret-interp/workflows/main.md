---
name: workflows/main
outputs:
  out: String
---

## flow

```step
c <- builtin/llm-generate(system = "s", prompt = "key: ${ctx.env.API_KEY}", model = "m")
return { out = ${c.text} }
```
