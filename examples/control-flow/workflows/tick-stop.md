---
name: workflows/tick-stop
inputs: {}
outputs:
  done: Bool
imports:
  - workflows/tick-pred
  - workflows/tick-body
---

## flow

Minimal **`while`** example (§4.3): predicate and body are separate
sub-workflows; `predicate_args` / `body_args` are required records (`{}` when
empty). Here the predicate stops immediately, so the body never runs.

For a loop that executes the body until `max_iterations`, see the tests in
`ControlFlowSpec` — the predicate must return `continue = false` before the cap,
or the run aborts with a `user` error.

```step
_ <- while(
  predicate = workflows/tick-pred,
  predicate_args = {},
  body = workflows/tick-body,
  body_args = {},
  max_iterations = 5
) @loop
return { done = true }
```
