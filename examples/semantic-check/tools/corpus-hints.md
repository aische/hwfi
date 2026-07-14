---
name: tools/corpus-hints
inputs:
  slices: List<types/corpus-slice>
  clusters: List<types/corpus-cluster>
outputs:
  findings: List<types/finding>
imports:
  - builtin/list-concat
  - builtin/record-map
  - tools/corpus-cluster-divergence-hint
  - tools/corpus-cluster-redundancy-hint
  - tools/corpus-compression-outlier-hint
  - tools/corpus-entropy-outlier-hint
---

## flow

Layer 2 review hints from corpus metrics and similarity clusters.

```step
entropy_rows <- foreach slice in ${inputs.slices} {
  pack <- tools/corpus-entropy-outlier-hint(
    slice = ${slice},
    slices = ${inputs.slices}
  ) @entropy
  return { findings = ${pack.findings} }
} @entropy

compression_rows <- foreach slice in ${inputs.slices} {
  pack <- tools/corpus-compression-outlier-hint(
    slice = ${slice},
    slices = ${inputs.slices}
  ) @compression
  return { findings = ${pack.findings} }
} @compression

cluster_rows <- foreach cluster in ${inputs.clusters} {
  pack <- tools/corpus-cluster-redundancy-hint(cluster = ${cluster}) @cluster
  return { findings = ${pack.findings} }
} @clusters

divergence_rows <- foreach cluster in ${inputs.clusters} {
  pair_rows <- foreach left in ${cluster.members} {
    inner <- foreach right in ${cluster.members} {
      pack <- tools/corpus-cluster-divergence-hint(
        left_id = ${left},
        right_id = ${right},
        cluster = ${cluster},
        slices = ${inputs.slices}
      ) @pair
      return { findings = ${pack.findings} }
    } @inner
    layers <- builtin/record-map(items = ${inner}, field = "findings") @pick
    flat <- builtin/list-concat(lists = ${layers.values}) @flat
    return { findings = ${flat.items} }
  } @pairs
  layers <- builtin/record-map(items = ${pair_rows}, field = "findings") @pick
  flat <- builtin/list-concat(lists = ${layers.values}) @flat
  return { findings = ${flat.items} }
} @divergence

entropy_layers <- builtin/record-map(items = ${entropy_rows}, field = "findings") @e
compression_layers <- builtin/record-map(items = ${compression_rows}, field = "findings") @c
cluster_layers <- builtin/record-map(items = ${cluster_rows}, field = "findings") @k
divergence_layers <- builtin/record-map(items = ${divergence_rows}, field = "findings") @d

entropy_flat <- builtin/list-concat(lists = ${entropy_layers.values}) @ef
compression_flat <- builtin/list-concat(lists = ${compression_layers.values}) @cf
cluster_flat <- builtin/list-concat(lists = ${cluster_layers.values}) @kf
divergence_flat <- builtin/list-concat(lists = ${divergence_layers.values}) @df

merged <- builtin/list-concat(lists = [
  ${entropy_flat.items},
  ${compression_flat.items},
  ${cluster_flat.items},
  ${divergence_flat.items}
]) @merged

return { findings = ${merged.items} }
```
