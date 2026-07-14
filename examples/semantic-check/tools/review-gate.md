---
name: tools/review-gate
inputs:
  clusters: List<types/corpus-cluster>
  prose_hints: List<types/finding>
  speech_act_hints: List<types/speech-act-hint>
  slices: List<types/corpus-slice>
outputs:
  items: List<types/review-gate-item>
imports:
  - builtin/list-concat
  - builtin/record-map
  - tools/review-gate-dedupe-cap
  - tools/review-gate-divergence-pair
  - tools/review-gate-prose-row
  - tools/review-gate-redundancy-cluster
  - tools/review-gate-speech-row
---

## flow

Select high-signal slices for layer 3 LLM review. Priority order: redundancy
warnings, cluster divergence, coverage gaps, dead references. Entropy outliers
and unguarded-directive hints are excluded.

```step
redundancy_rows <- foreach cluster in ${inputs.clusters} {
  pack <- tools/review-gate-redundancy-cluster(
    cluster = ${cluster},
    slices = ${inputs.slices}
  ) @row
  return { items = ${pack.items} }
} @redundancy

divergence_rows <- foreach cluster in ${inputs.clusters} {
  pair_rows <- foreach left in ${cluster.members} {
    inner <- foreach right in ${cluster.members} {
      pack <- tools/review-gate-divergence-pair(
        left_id = ${left},
        right_id = ${right},
        cluster = ${cluster},
        slices = ${inputs.slices}
      ) @pair
      return { items = ${pack.items} }
    } @inner
    layers <- builtin/record-map(items = ${inner}, field = "items") @pick
    flat <- builtin/list-concat(lists = ${layers.values}) @flat
    return { items = ${flat.items} }
  } @pairs
  layers <- builtin/record-map(items = ${pair_rows}, field = "items") @pick
  flat <- builtin/list-concat(lists = ${layers.values}) @flat
  return { items = ${flat.items} }
} @divergence

speech_rows <- foreach hint in ${inputs.speech_act_hints} {
  pack <- tools/review-gate-speech-row(
    hint = ${hint},
    slices = ${inputs.slices}
  ) @row
  return { items = ${pack.items} }
} @speech

prose_rows <- foreach hint in ${inputs.prose_hints} {
  pack <- tools/review-gate-prose-row(hint = ${hint}) @row
  return { items = ${pack.items} }
} @prose

redundancy_layers <- builtin/record-map(items = ${redundancy_rows}, field = "items") @r
divergence_layers <- builtin/record-map(items = ${divergence_rows}, field = "items") @d
speech_layers <- builtin/record-map(items = ${speech_rows}, field = "items") @s
prose_layers <- builtin/record-map(items = ${prose_rows}, field = "items") @p

redundancy_flat <- builtin/list-concat(lists = ${redundancy_layers.values}) @rf
divergence_flat <- builtin/list-concat(lists = ${divergence_layers.values}) @df
speech_flat <- builtin/list-concat(lists = ${speech_layers.values}) @sf
prose_flat <- builtin/list-concat(lists = ${prose_layers.values}) @pf

merged <- builtin/list-concat(lists = [
  ${redundancy_flat.items},
  ${divergence_flat.items},
  ${speech_flat.items},
  ${prose_flat.items}
]) @merged

capped <- tools/review-gate-dedupe-cap(
  items = ${merged.items}
) @cap

return { items = ${capped.items} }
```
