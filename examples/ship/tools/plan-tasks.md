---
name: tools/plan-tasks
inputs:
  plan: Json
outputs:
  tasks: List<Json>
imports:
  - tools/plan-task-at
---

## flow

Bridge `plan.tasks` (JSON object keyed by slot) to `List<Json>` for `foreach`.
Collects slots `"0"` … `"7"`; missing slots are JSON `null`. The orchestrator
skips null tasks (no build agent) via `json-get` on `id`.

```step
t0 <- tools/plan-task-at(plan = ${inputs.plan}, slot = "0")
t1 <- tools/plan-task-at(plan = ${inputs.plan}, slot = "1")
t2 <- tools/plan-task-at(plan = ${inputs.plan}, slot = "2")
t3 <- tools/plan-task-at(plan = ${inputs.plan}, slot = "3")
t4 <- tools/plan-task-at(plan = ${inputs.plan}, slot = "4")
t5 <- tools/plan-task-at(plan = ${inputs.plan}, slot = "5")
t6 <- tools/plan-task-at(plan = ${inputs.plan}, slot = "6")
t7 <- tools/plan-task-at(plan = ${inputs.plan}, slot = "7")
return {
  tasks = [
    ${t0.value},
    ${t1.value},
    ${t2.value},
    ${t3.value},
    ${t4.value},
    ${t5.value},
    ${t6.value},
    ${t7.value}
  ]
}
```
