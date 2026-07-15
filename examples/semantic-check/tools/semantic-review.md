---
name: tools/semantic-review
inputs:
  project: types/project-check
  entry: String
outputs:
  report_text: String
imports:
  - builtin/concat
  - builtin/record-map
  - tools/build-catalog
  - tools/corpus-clusters
  - tools/corpus-hints
  - tools/corpus-profile
  - tools/corpus-profile-public
  - tools/entry-finding
  - tools/prose-hints
  - tools/referential-scan
  - tools/review-gate
  - tools/speech-act-align
  - tools/speech-act-scan
---

## flow

Layers 0–2b deterministic semantic review over a `check-project` result. Always
computes `review_gate` for optional follow-up via `semantic-pragmatic`.

```step
catalog_pack <- tools/build-catalog(declarations = ${inputs.project.declarations}) @catalog

structural_errors <- foreach err in ${inputs.project.errors} {
  return {
    severity = "error",
    category = "policy",
    location = { file = "", section = "" },
    claim = "Project failed structural type check",
    evidence = ${err},
    suggestion = "Fix the parse or type error reported by hwfi check"
  }
} @l0e

structural_warnings <- foreach warn in ${inputs.project.warnings} {
  return {
    severity = "warning",
    category = "policy",
    location = { file = "", section = "" },
    claim = "Project check warning",
    evidence = ${warn},
    suggestion = "Review the warning text"
  }
} @l0w

entry_pack <- tools/entry-finding(
  entry = ${inputs.entry},
  catalog = ${catalog_pack.catalog}
) @entry

prose_pack <- tools/prose-hints(catalog = ${catalog_pack.catalog}) @prose

ref_pack <- tools/referential-scan(
  declarations = ${inputs.project.declarations},
  catalog = ${catalog_pack.catalog}
) @refs

corpus_pack <- tools/corpus-profile(
  declarations = ${inputs.project.declarations}
) @corpus

cluster_pack <- tools/corpus-clusters(slices = ${corpus_pack.slices}) @clusters

hint_pack <- tools/corpus-hints(
  slices = ${corpus_pack.slices},
  clusters = ${cluster_pack.clusters}
) @hints

speech_pack <- tools/speech-act-scan(slices = ${corpus_pack.slices}) @acts

align_pack <- tools/speech-act-align(
  declarations = ${inputs.project.declarations},
  tags = ${speech_pack.tags}
) @align

profile_rows <- foreach slice in ${corpus_pack.slices} {
  pack <- tools/corpus-profile-public(slice = ${slice}) @row
  return { row = ${pack.row} }
} @profile

profile_layers <- builtin/record-map(items = ${profile_rows}, field = "row") @pick

gate_pack <- tools/review-gate(
  clusters = ${cluster_pack.clusters},
  prose_hints = ${prose_pack.findings},
  speech_act_hints = ${align_pack.hints},
  slices = ${corpus_pack.slices}
) @gate

gate_rows <- foreach item in ${gate_pack.items} {
  return { item = ${item} }
} @gate_rows

gate_layers <- builtin/record-map(items = ${gate_rows}, field = "item") @gate_map

report_text <- builtin/concat(parts = [
  "{\n",
  "  \"schema\": \"semantic-report/v1\",\n",
  "  \"mode\": \"deterministic\",\n",
  "  \"entry\": \"", ${inputs.entry}, "\",\n",
  "  \"ok\": ", "${inputs.project.ok}", ",\n",
  "  \"check_error\": \"", ${inputs.project.error}, "\",\n",
  "  \"review_gate\": ", "${gate_layers.values}", ",\n",
  "  \"structural_errors\": ", "${structural_errors}", ",\n",
  "  \"structural_warnings\": ", "${structural_warnings}", ",\n",
  "  \"entry_findings\": ", "${entry_pack.findings}", ",\n",
  "  \"prose_hints\": ", "${prose_pack.findings}", ",\n",
  "  \"step_referential\": ", "${ref_pack.step_results}", ",\n",
  "  \"corpus_profile\": ", "${profile_layers.values}", ",\n",
  "  \"corpus_hints\": ", "${hint_pack.findings}", ",\n",
  "  \"speech_act_hints\": ", "${align_pack.hints}", "\n",
  "}\n"
]) @report

return { report_text = ${report_text.text} }
```
