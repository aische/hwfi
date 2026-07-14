---
name: tools/prose-section-scan
inputs:
  file: String
  section: String
  body: String
  catalog: List<String>
outputs:
  findings: List<types/finding>
imports:
  - builtin/resolve-qnames-in-text
---

## flow

Scan one markdown section body for unresolved qname mentions.

```step
resolved <- builtin/resolve-qnames-in-text(
  text = ${inputs.body},
  catalog = ${inputs.catalog},
  include_builtins = true,
  unresolved_only = true,
  exclude_step_fences = true
) @scan

findings <- foreach mention in ${resolved.mentions} {
  return {
    severity = "warning",
    category = "dead_reference",
    location = { file = ${inputs.file}, section = ${inputs.section} },
    claim = "Prose mentions a qname not in the project catalog",
    evidence = ${mention.qname},
    suggestion = "Add the declaration or fix the qname spelling"
  }
} @rows

return { findings = ${findings} }
```
