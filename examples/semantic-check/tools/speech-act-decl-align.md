---
name: tools/speech-act-decl-align
inputs:
  decl: types/declaration-summary
  tags: List<types/speech-act-tag>
outputs:
  hints: List<types/speech-act-hint>
imports:
  - builtin/list-concat
  - builtin/record-filter
  - builtin/record-map
  - tools/speech-act-bare-directive-hint
  - tools/speech-act-declarative-hint
  - tools/speech-act-step-align
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

file_tags <- builtin/record-filter(
  items = ${inputs.tags},
  where = { location = { file = ${inputs.decl.path} } }
) @file_tags

tag_rows <- foreach tag in ${file_tags.items} {
  bare <- tools/speech-act-bare-directive-hint(tag = ${tag}) @bare
  decl <- tools/speech-act-declarative-hint(tag = ${tag}) @decl_hint
  merged <- builtin/list-concat(lists = [${bare.hints}, ${decl.hints}]) @merged
  return { hints = ${merged.items} }
} @tag_loop

step_layers <- builtin/record-map(items = ${step_rows}, field = "hints") @step_map
tag_layers <- builtin/record-map(items = ${tag_rows}, field = "hints") @tag_map

step_flat <- builtin/list-concat(lists = ${step_layers.values}) @step_flat
tag_flat <- builtin/list-concat(lists = ${tag_layers.values}) @tag_flat

merged <- builtin/list-concat(lists = [${step_flat.items}, ${tag_flat.items}]) @merged

return { hints = ${merged.items} }
```
