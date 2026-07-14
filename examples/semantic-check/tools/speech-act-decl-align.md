---
name: tools/speech-act-decl-align
inputs:
  decl: types/declaration-summary
  tags: List<types/speech-act-tag>
outputs:
  hints: List<types/speech-act-hint>
imports:
  - builtin/list-concat
  - builtin/record-map
  - tools/empty-speech-act-hints
  - tools/speech-act-bare-directive-hint
  - tools/speech-act-declarative-hint
  - tools/speech-act-step-align
  - tools/strings-equal
---

## flow

Speech-act alignment for one declaration (steps + tag felicity).

```step
step_rows <- foreach step in ${inputs.decl.steps} {
  pack <- tools/speech-act-step-align(
    decl = ${inputs.decl},
    step = ${step},
    tags = ${inputs.tags}
  ) @step_row
  return { hints = ${pack.hints} }
} @step_loop

tag_rows <- foreach tag in ${inputs.tags} {
  file <- tools/strings-equal(
    left = ${tag.location.file},
    right = ${inputs.decl.path}
  ) @file_chk

  pack <- if ${file.equal} {
    bare <- tools/speech-act-bare-directive-hint(tag = ${tag}) @bare
    decl <- tools/speech-act-declarative-hint(tag = ${tag}) @decl_hint
    merged <- builtin/list-concat(lists = [${bare.hints}, ${decl.hints}]) @merged
    return { hints = ${merged.items} }
  } else {
    empty <- tools/empty-speech-act-hints() @skip
    return { hints = ${empty.hints} }
  } @scope

  return { hints = ${pack.hints} }
} @tag_loop

step_layers <- builtin/record-map(items = ${step_rows}, field = "hints") @step_map
tag_layers <- builtin/record-map(items = ${tag_rows}, field = "hints") @tag_map

step_flat <- builtin/list-concat(lists = ${step_layers.values}) @step_flat
tag_flat <- builtin/list-concat(lists = ${tag_layers.values}) @tag_flat

merged <- builtin/list-concat(lists = [${step_flat.items}, ${tag_flat.items}]) @merged

return { hints = ${merged.items} }
```
