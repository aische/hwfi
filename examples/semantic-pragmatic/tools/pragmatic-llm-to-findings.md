---
name: tools/pragmatic-llm-to-findings
inputs:
  value: Json
  location: types/location
outputs:
  findings: List<types/finding>
imports:
  - builtin/list-concat
  - tools/pragmatic-contradiction-findings
  - tools/pragmatic-felicity-findings
---

## flow

Convert one `llm-gen-object` pragmatic review into `types/finding` rows.

```step
felicity <- tools/pragmatic-felicity-findings(
  value = ${inputs.value},
  location = ${inputs.location}
) @felicity

contradiction <- tools/pragmatic-contradiction-findings(
  value = ${inputs.value},
  location = ${inputs.location}
) @contradiction

merged <- builtin/list-concat(lists = [
  ${felicity.findings},
  ${contradiction.findings}
]) @merged

return { findings = ${merged.items} }
```
