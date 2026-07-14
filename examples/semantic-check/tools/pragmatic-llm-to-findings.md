---
name: tools/pragmatic-llm-to-findings
inputs:
  value: Json
  location: types/location
outputs:
  findings: List<types/finding>
imports:
  - builtin/list-concat
  - tools/pragmatic-clarity-finding
  - tools/pragmatic-contradiction-findings
  - tools/pragmatic-felicity-findings
  - tools/pragmatic-force-finding
---

## flow

Convert one `llm-gen-object` pragmatic review into `types/finding` rows.

```step
force <- tools/pragmatic-force-finding(
  value = ${inputs.value},
  location = ${inputs.location}
) @force

felicity <- tools/pragmatic-felicity-findings(
  value = ${inputs.value},
  location = ${inputs.location}
) @felicity

contradiction <- tools/pragmatic-contradiction-findings(
  value = ${inputs.value},
  location = ${inputs.location}
) @contradiction

clarity <- tools/pragmatic-clarity-finding(
  value = ${inputs.value},
  location = ${inputs.location}
) @clarity

merged <- builtin/list-concat(lists = [
  ${force.findings},
  ${felicity.findings},
  ${contradiction.findings},
  ${clarity.findings}
]) @merged

return { findings = ${merged.items} }
```
