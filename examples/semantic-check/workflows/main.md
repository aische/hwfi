---
name: workflows/main
inputs:
  path: FileRef
  entry: String
outputs:
  report_path: String
  ok: Bool
  check_error: String
imports:
  - builtin/check-project
  - builtin/write-file
  - tools/semantic-review
---

## overview

Semantic review workflow (layers 0–1). The checker project runs from
`examples/semantic-check`; the **workspace** is the target project under review.

Layer 0 uses `builtin/check-project` for parse/type diagnostics. Layer 1 (interim)
uses workspace `grep` to surface qname-like lines until
`resolve-qnames-in-text` ships.

## flow

```step
project <- builtin/check-project(path = ${inputs.path}) @check

review <- tools/semantic-review(
  project = ${project},
  entry = ${inputs.entry}
) @review

_ <- builtin/write-file(
  path = "semantic-report.json",
  text = ${review.report_text}
) @write

return {
  report_path = "semantic-report.json",
  ok = ${project.ok},
  check_error = ${project.error}
}
```
