---
name: tools/review-gate
inputs:
  corpus_hints: List<types/finding>
  speech_act_hints: List<types/speech-act-hint>
  slices: List<types/corpus-slice>
outputs:
  items: List<types/review-gate-item>
imports:
  - builtin/list-concat
  - builtin/record-map
  - tools/corpus-hint-is-gate
  - tools/empty-review-gate-items
  - tools/review-gate-dedupe-cap
  - tools/review-gate-from-finding
  - tools/review-gate-from-speech-hint
  - tools/speech-act-hint-is-gate
---

## flow

Union layer 2 / 2b gate signals into bounded slice list for layer 3 LLM review.

```step
corpus_rows <- foreach hint in ${inputs.corpus_hints} {
  gate <- tools/corpus-hint-is-gate(hint = ${hint}) @gate

  pack <- if ${gate.gate} {
    item <- tools/review-gate-from-finding(
      hint = ${hint},
      slices = ${inputs.slices}
    ) @item
    return { items = ${item.items} }
  } else {
    empty <- tools/empty-review-gate-items() @skip
    return { items = ${empty.items} }
  } @branch

  return { items = ${pack.items} }
} @corpus

speech_rows <- foreach hint in ${inputs.speech_act_hints} {
  gate <- tools/speech-act-hint-is-gate(hint = ${hint}) @gate

  pack <- if ${gate.gate} {
    item <- tools/review-gate-from-speech-hint(
      hint = ${hint},
      slices = ${inputs.slices}
    ) @item
    return { items = ${item.items} }
  } else {
    empty <- tools/empty-review-gate-items() @skip
    return { items = ${empty.items} }
  } @branch

  return { items = ${pack.items} }
} @speech

corpus_layers <- builtin/record-map(items = ${corpus_rows}, field = "items") @c
speech_layers <- builtin/record-map(items = ${speech_rows}, field = "items") @s

corpus_flat <- builtin/list-concat(lists = ${corpus_layers.values}) @cf
speech_flat <- builtin/list-concat(lists = ${speech_layers.values}) @sf

merged <- builtin/list-concat(lists = [${corpus_flat.items}, ${speech_flat.items}]) @merged

capped <- tools/review-gate-dedupe-cap(
  items = ${merged.items},
  slices = ${inputs.slices}
) @cap

return { items = ${capped.items} }
```
