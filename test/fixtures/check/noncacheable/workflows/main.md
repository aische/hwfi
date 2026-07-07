---
name: workflows/main
outputs:
  out: String
---

## flow

Both steps are non-cacheable: one calls builtin/introspect, the other reads
the volatile ctx.trace (§8.1).

```step
d <- builtin/introspect()
c <- builtin/llm-generate(system = "s", prompt = "trace so far: ${ctx.trace}", model = "m")
return { out = ${c.text} }
```
