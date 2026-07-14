---
name: tools/step-ref-findings
inputs:
  step: types/step-summary
  file: String
  catalog: List<types/catalog-entry>
outputs:
  bare: types/finding-matrix
  agent: types/finding-matrix
imports:
  - tools/unresolved-finding
---

## flow

Layer 1 referential scan for one step: resolve `bare_qnames` and static
`agent_tools` against the project catalog (nested `foreach`).

```step
bare <- foreach mention in ${inputs.step.bare_qnames} {
  pack <- tools/unresolved-finding(
    mention = ${mention},
    catalog = ${inputs.catalog},
    file = ${inputs.file},
    section = ${inputs.step.step_id},
    claim = "Step expression references an unknown qname",
    evidence = ${mention},
    suggestion = "Import the declaration, fix the typo, or remove the reference"
  ) @bare
  inner <- foreach f in ${pack.findings} {
    return {
      severity = ${f.severity},
      category = ${f.category},
      location = ${f.location},
      claim = ${f.claim},
      evidence = ${f.evidence},
      suggestion = ${f.suggestion}
    }
  } @inner
} @bare_loop

agent <- foreach tool in ${inputs.step.agent_tools} {
  pack <- tools/unresolved-finding(
    mention = ${tool},
    catalog = ${inputs.catalog},
    file = ${inputs.file},
    section = ${inputs.step.step_id},
    claim = "Agent tool list references an unknown qname",
    evidence = ${tool},
    suggestion = "Add the tool to imports and the project, or remove it from the agent tools list"
  ) @tool
  inner <- foreach f in ${pack.findings} {
    return {
      severity = ${f.severity},
      category = ${f.category},
      location = ${f.location},
      claim = ${f.claim},
      evidence = ${f.evidence},
      suggestion = ${f.suggestion}
    }
  } @inner
} @agent_loop

return { bare = ${bare}, agent = ${agent} }
```
