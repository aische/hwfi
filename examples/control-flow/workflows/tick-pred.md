---
name: workflows/tick-pred
inputs: {}
outputs:
  continue: Bool
  reason: String
---

## flow

Predicate for the `while` example (`workflows/tick-stop`). Returns
`continue = false` immediately so the body never runs — a minimal successful
`while` invocation (§4.3).

```step
return { continue = false, reason = "no ticks requested" }
```
