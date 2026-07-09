---
name: workflows/continue-pred
inputs: {}
outputs:
  continue: Bool
  reason: String
---

## flow

Predicate that always requests another repair round. Pair with `max_iterations` on
the enclosing `while` to cap retries (v1 has no `exit_code` comparisons in the
expression language — see README).

```step
return { continue = true, reason = "repair round requested" }
```
