---
name: tools/is-builtin
inputs:
  mention: String
outputs:
  ok: Bool
imports:
  - builtin/record-filter
  - builtin/record-map
  - tools/nonempty
  - tools/catalog-row
---

## flow

Succeed when `mention` names a shipped engine builtin; fail catchably otherwise.

```step
rows <- foreach name in [
  "builtin/read-file",
  "builtin/write-file",
  "builtin/list-dir",
  "builtin/read-file-slice",
  "builtin/find-files",
  "builtin/grep",
  "builtin/edit-file",
  "builtin/move-file",
  "builtin/copy-file",
  "builtin/remove-file",
  "builtin/make-dir",
  "builtin/remove-dir",
  "builtin/exec",
  "builtin/llm-generate",
  "builtin/llm-chat",
  "builtin/llm-gen-object",
  "builtin/introspect",
  "builtin/llm-agent",
  "builtin/llm-agent-object",
  "builtin/eval-workflow",
  "builtin/list-runs",
  "builtin/read-run-trace",
  "builtin/trace-slice",
  "builtin/json-get",
  "builtin/json-values",
  "builtin/concat",
  "builtin/record-merge",
  "builtin/record-filter",
  "builtin/record-map",
  "builtin/log",
  "builtin/discover-skills",
  "builtin/load-skill",
  "builtin/check-project",
  "builtin/parse-markdown",
  "builtin/text-metrics",
  "builtin/text-similarity",
  "builtin/text-search-corpus"
] {
  row <- tools/catalog-row(qname = ${name}) @row
} @builtins

picked <- builtin/record-map(items = ${rows}, field = "row") @pick

hits <- builtin/record-filter(
  items = ${picked.values},
  field = "qname",
  equals = ${inputs.mention}
) @filter

_ <- tools/nonempty(items = ${hits.items}) @probe

return { ok = true }
```
