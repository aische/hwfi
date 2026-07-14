---
name: tools/semantic-review
inputs:
  project: types/project-check
  entry: String
outputs:
  report_text: String
imports:
  - builtin/concat
  - tools/build-catalog
  - tools/entry-finding
  - tools/prose-hints
  - tools/referential-scan
---

## flow

Layers 0–1 semantic review over a `check-project` result.

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

report_text <- builtin/concat(parts = [
  "{\n",
  "  \"schema\": \"semantic-report/v0\",\n",
  "  \"entry\": \"", ${inputs.entry}, "\",\n",
  "  \"ok\": ", "${inputs.project.ok}", ",\n",
  "  \"check_error\": \"", ${inputs.project.error}, "\",\n",
  "  \"structural_errors\": ", "${structural_errors}", ",\n",
  "  \"structural_warnings\": ", "${structural_warnings}", ",\n",
  "  \"entry_findings\": ", "${entry_pack.findings}", ",\n",
  "  \"prose_hints\": ", "${prose_pack.findings}", ",\n",
  "  \"step_referential\": ", "${ref_pack.step_results}", "\n",
  "}\n"
]) @report

return { report_text = ${report_text.text} }
```
