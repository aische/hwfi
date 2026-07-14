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
  - tools/entry-finding
  - tools/prose-hints
  - tools/referential-scan
  - tools/error-finding
  - tools/warning-finding
---

## flow

Layers 0–1 semantic review over a `check-project` result.

```step
catalog_pack <- tools/build-catalog(declarations = ${inputs.project.declarations}) @catalog

error_rows <- foreach err in ${inputs.project.errors} {
  row <- tools/error-finding(message = ${err}) @row
} @l0e

error_pick <- builtin/record-map(items = ${error_rows}, field = "finding") @l0pick

warning_rows <- foreach warn in ${inputs.project.warnings} {
  row <- tools/warning-finding(message = ${warn}) @row
} @l0w

warning_pick <- builtin/record-map(items = ${warning_rows}, field = "finding") @l0wpick

entry_pack <- tools/entry-finding(
  entry = ${inputs.entry},
  catalog = ${catalog_pack.catalog}
) @entry

prose_pack <- tools/prose-hints() @prose

ref_pack <- tools/referential-scan(
  declarations = ${inputs.project.declarations},
  catalog = ${catalog_pack.catalog}
) @refs

report_text <- builtin/concat(parts = [
  "{\n",
  "  \"schema\": \"semantic-report/v0\",\n",
  "  \"entry\": \"", ${inputs.entry}, "\",\n",
  "  \"ok\": ", "${inputs.project.ok}", ",\n",
  "  \"check_error\": \"", ${inputs.project.error}, "\",\n",
  "  \"structural_errors\": ", "${error_pick.values}", ",\n",
  "  \"structural_warnings\": ", "${warning_pick.values}", ",\n",
  "  \"entry_findings\": ", "${entry_pack.findings}", ",\n",
  "  \"prose_hints\": ", "${prose_pack.findings}", ",\n",
  "  \"step_referential\": ", "${ref_pack.step_results}", "\n",
  "}\n"
]) @report

return { report_text = ${report_text.text} }
```
