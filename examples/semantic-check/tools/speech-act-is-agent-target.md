---
name: tools/speech-act-is-agent-target
inputs:
  target: String
outputs:
  ok: Bool
imports:
  - tools/strings-equal
---

## flow

True when the step target is an LLM agent builtin.

```step
agent <- tools/strings-equal(
  left = ${inputs.target},
  right = "builtin/llm-agent"
) @agent

pack <- if ${agent.equal} {
  return { ok = true }
} else {
  obj <- tools/strings-equal(
    left = ${inputs.target},
    right = "builtin/llm-agent-object"
  ) @obj
  branch <- if ${obj.equal} {
    return { ok = true }
  } else {
    return { ok = false }
  } @branch
  return { ok = ${branch.ok} }
} @kind

return { ok = ${pack.ok} }
```
