---
name: tools/plan-task-at
inputs:
  plan: Json
  slot: String
outputs:
  value: Json
imports:
  - builtin/json-get
  - builtin/concat
---

## flow

Extract one planner task slot from the structured plan. `tasks` is an object
keyed by `"0"`, `"1"`, … (see `plan-schema.json`). Missing slots yield JSON
`null` in `value`.

```step
path <- builtin/concat(parts = ["tasks.", ${inputs.slot}])
got <- builtin/json-get(json = ${inputs.plan}, path = ${path.text})
return { value = ${got.value} }
```
