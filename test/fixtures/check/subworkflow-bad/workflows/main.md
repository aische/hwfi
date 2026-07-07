---
name: workflows/main
outputs:
  greeting: String
---

## flow

Calls the greet tool with a wrong-typed argument; the callee signature is
enforced (§5.6.2, A6).

```step
g <- tools/greet(name = 42)
return { greeting = ${g.greeting} }
```
