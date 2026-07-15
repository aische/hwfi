---
name: tools/render-findings-body
inputs:
  findings: List<Json>
outputs:
  text: String
imports:
  - builtin/concat
  - builtin/list-concat
  - builtin/record-map
  - tools/finding-line
  - tools/hit-nonempty
---

## flow

Render actionable findings as markdown bullets, or a none message.

```step
rows <- foreach finding in ${inputs.findings} {
  line <- tools/finding-line(finding = ${finding}) @line
  return { lines = [${line.line}] }
} @rows

hits <- foreach row in ${rows} {
  return { hit = "yes" }
} @hits

pack <- try {
  _ <- tools/hit-nonempty(items = ${hits}) @hit

  layers <- builtin/record-map(items = ${rows}, field = "lines") @pick
  lines_flat <- builtin/list-concat(lists = ${layers.values}) @lines

  merged <- builtin/list-concat(
    lists = [["\n## Findings\n\n"], ${lines_flat.items}]
  ) @merged

  body <- builtin/concat(parts = ${merged.items}) @body

  return { text = ${body.text} }
} catch {
  none <- builtin/concat(
    parts = ["\n## Findings\n\n", "No actionable findings.\n"]
  ) @none
  return { text = ${none.text} }
} @probe

return { text = ${pack.text} }
```
