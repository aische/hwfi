---
name: tools/speech-act-tag-hints
inputs:
  tag: types/speech-act-tag
outputs:
  hints: List<types/speech-act-hint>
imports:
  - builtin/list-concat
  - tools/speech-act-bare-directive-hint
  - tools/speech-act-declarative-hint
---

## flow

Felicity hints for one in-file speech-act tag (bare directive + declarative).

```step
bare <- tools/speech-act-bare-directive-hint(tag = ${inputs.tag}) @bare
decl <- tools/speech-act-declarative-hint(tag = ${inputs.tag}) @decl

merged <- builtin/list-concat(lists = [${bare.hints}, ${decl.hints}]) @merged

return { hints = ${merged.items} }
```
