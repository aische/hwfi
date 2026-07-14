---
name: tools/speech-act-align
inputs:
  declarations: List<types/declaration-summary>
  tags: List<types/speech-act-tag>
outputs:
  hints: List<types/speech-act-hint>
imports:
  - builtin/list-concat
  - builtin/record-map
  - tools/speech-act-decl-align
---

## flow

Layer 2b: compare step metadata to agent-section act profiles.

```step
rows <- foreach decl in ${inputs.declarations} {
  pack <- tools/speech-act-decl-align(
    decl = ${decl},
    tags = ${inputs.tags}
  ) @decl
  return { hints = ${pack.hints} }
} @rows

layers <- builtin/record-map(items = ${rows}, field = "hints") @pick
flat <- builtin/list-concat(lists = ${layers.values}) @flat

return { hints = ${flat.items} }
```
