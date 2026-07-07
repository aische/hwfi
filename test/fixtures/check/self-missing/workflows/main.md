---
name: workflows/main
outputs:
  text: String
---

## flow

```step
c <- builtin/llm-generate(system = @self#nope, prompt = "p", model = "m")
return { text = ${c.text} }
```
