---
name: workflows/plan
inputs:
  spec: String
  tasks: List<types/task>
  schema: Json
outputs:
  plan: Json
imports:
  - builtin/llm-gen-object
  - builtin/concat
---

## planner

You are a staff engineer planning a small shell-library repair job. Read the user
spec and the task list, then return structured JSON matching the schema. Be
concrete about approach and risks.

## flow

```step
brief <- builtin/concat(
  parts = [
    "Engineer: ",
    ${ctx.env.ENGINEER_NAME},
    "\nSpec:\n",
    ${inputs.spec},
    "\n\nTasks:\n",
    "${inputs.tasks}"
  ]
)
obj <- builtin/llm-gen-object(
  system = @self#planner,
  prompt = ${brief.text},
  schema = ${inputs.schema},
  model  = "smart"
) @plan
return { plan = ${obj.value} }
```
