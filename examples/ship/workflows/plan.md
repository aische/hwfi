---
name: workflows/plan
inputs:
  spec: String
outputs:
  plan: Json
imports:
  - builtin/llm-gen-object
  - builtin/concat
---

## planner

You are a staff engineer planning a greenfield coding job in an **empty workspace**.
Read the user spec and return structured JSON matching the schema described in the
prompt. Be concrete about stack choice, task breakdown, and verification.

**Tasks shape:** emit `tasks` as a JSON **object** keyed by string slots `"0"`,
`"1"`, `"2"`, … (not an array). Each task has `id`, `description`, and optional
`verify_command` (a single shell one-liner the builder can run, e.g.
`npm run build` or `cabal build`). Use consecutive slots starting at `"0"`;
omit unused higher slots.

## flow

```step
brief <- builtin/concat(
  parts = [
    "Spec:\n",
    ${inputs.spec},
    "\n\nReturn JSON with fields: goal, stack, approach, risks (string array), tasks (object keyed by \"0\",\"1\",...). See examples/ship/plan-schema.json."
  ]
)
obj <- builtin/llm-gen-object(
  system = @self#planner,
  prompt = ${brief.text},
  schema = null,
  model = "smart"
) @plan
return { plan = ${obj.value} }
```
