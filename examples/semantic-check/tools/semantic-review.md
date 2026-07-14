---
name: tools/semantic-review
inputs:
  project: types/project-check
  entry: String
  mode: String
  schema: Json
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
  - tools/empty-findings
  - tools/empty-review-gate-items
  - tools/entry-finding
  - tools/mode-is-exploratory
  - tools/pragmatic-review
  - tools/prose-hints
  - tools/referential-scan
  - tools/review-gate
  - tools/speech-act-align
  - tools/speech-act-scan
---

## flow

Layers 0–2 semantic review over a `check-project` result; optional layer 3 when
`mode=exploratory`.

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

mode_pack <- tools/mode-is-exploratory(mode = ${inputs.mode}) @mode

layer3 <- if ${mode_pack.exploratory} {
  gate_pack <- tools/review-gate(
    corpus_hints = ${hint_pack.findings},
    speech_act_hints = ${align_pack.hints},
    slices = ${corpus_pack.slices}
  ) @gate

  pragmatic_pack <- tools/pragmatic-review(
    items = ${gate_pack.items},
    schema = ${inputs.schema}
  ) @pragmatic

  gate_rows <- foreach item in ${gate_pack.items} {
    return { slice_id = ${item.slice_id} }
  } @gate_rows

  gate_layers <- builtin/record-map(items = ${gate_rows}, field = "slice_id") @gate_map

  return {
    pragmatic_findings = ${pragmatic_pack.findings},
    review_gate = ${gate_layers.values}
  }
} else {
  empty_findings <- tools/empty-findings() @ef
  empty_gate <- tools/empty-review-gate-items() @eg

  gate_rows <- foreach item in ${empty_gate.items} {
    return { slice_id = ${item.slice_id} }
  } @gate_rows

  gate_layers <- builtin/record-map(items = ${gate_rows}, field = "slice_id") @gate_map

  return {
    pragmatic_findings = ${empty_findings.findings},
    review_gate = ${gate_layers.values}
  }
} @layer3

report_text <- builtin/concat(parts = [
  "{\n",
  "  \"schema\": \"semantic-report/v1\",\n",
  "  \"mode\": \"", ${inputs.mode}, "\",\n",
  "  \"entry\": \"", ${inputs.entry}, "\",\n",
  "  \"ok\": ", "${inputs.project.ok}", ",\n",
  "  \"check_error\": \"", ${inputs.project.error}, "\",\n",
  "  \"review_gate\": ", "${layer3.review_gate}", ",\n",
  "  \"structural_errors\": ", "${structural_errors}", ",\n",
  "  \"structural_warnings\": ", "${structural_warnings}", ",\n",
  "  \"entry_findings\": ", "${entry_pack.findings}", ",\n",
  "  \"prose_hints\": ", "${prose_pack.findings}", ",\n",
  "  \"step_referential\": ", "${ref_pack.step_results}", ",\n",
  "  \"corpus_profile\": ", "${profile_layers.values}", ",\n",
  "  \"corpus_hints\": ", "${hint_pack.findings}", ",\n",
  "  \"speech_act_hints\": ", "${align_pack.hints}", ",\n",
  "  \"pragmatic_findings\": ", "${layer3.pragmatic_findings}", "\n",
  "}\n"
]) @report

return { report_text = ${report_text.text} }
```
