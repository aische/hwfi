---
name: tools/report-ok-label
inputs:
  report: Json
outputs:
  label: String
imports:
  - builtin/text-grep
  - tools/report-as-text
  - tools/string-nonempty
---

## flow

Map report `ok` to PASS/FAIL label text.

```step
text <- tools/report-as-text(report = ${inputs.report}) @text

pack <- try {
  got <- builtin/text-grep(
    text = ${text.text},
    pattern = "\"ok\":true"
  ) @got

  _ <- tools/string-nonempty(items = ${got.matches}) @hit

  return { label = "PASS" }
} catch {
  return { label = "FAIL" }
} @probe

return { label = ${pack.label} }
```
