---
name: tools/plan-tasks
inputs:
  plan: Json
outputs:
  tasks: List<Json>
imports:
  - builtin/json-values
---

## flow

Bridge `plan.tasks` (JSON object keyed by slot) to `List<Json>` for `foreach`.
Uses `builtin/json-values` to collect values in numeric key order and drop
JSON `null` entries (unused slots).

```step
got <- builtin/json-values(json = ${inputs.plan}, path = "tasks")
return { tasks = ${got.values} }
```
