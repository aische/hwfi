---
name: tools/is-builtin
inputs:
  mention: String
outputs:
  ok: Bool
imports:
  - builtin/record-filter
  - tools/nonempty
---

## flow

Succeed when `mention` names a shipped engine builtin; fail catchably otherwise.

```step
hits <- builtin/record-filter(
  items = [
    { qname = "builtin/read-file" },
    { qname = "builtin/write-file" },
    { qname = "builtin/list-dir" },
    { qname = "builtin/read-file-slice" },
    { qname = "builtin/find-files" },
    { qname = "builtin/grep" },
    { qname = "builtin/edit-file" },
    { qname = "builtin/move-file" },
    { qname = "builtin/copy-file" },
    { qname = "builtin/remove-file" },
    { qname = "builtin/make-dir" },
    { qname = "builtin/remove-dir" },
    { qname = "builtin/exec" },
    { qname = "builtin/llm-generate" },
    { qname = "builtin/llm-chat" },
    { qname = "builtin/llm-gen-object" },
    { qname = "builtin/introspect" },
    { qname = "builtin/llm-agent" },
    { qname = "builtin/llm-agent-object" },
    { qname = "builtin/eval-workflow" },
    { qname = "builtin/list-runs" },
    { qname = "builtin/read-run-trace" },
    { qname = "builtin/trace-slice" },
    { qname = "builtin/json-get" },
    { qname = "builtin/json-values" },
    { qname = "builtin/concat" },
    { qname = "builtin/record-merge" },
    { qname = "builtin/record-filter" },
    { qname = "builtin/record-map" },
    { qname = "builtin/log" },
    { qname = "builtin/discover-skills" },
    { qname = "builtin/load-skill" },
    { qname = "builtin/check-project" },
    { qname = "builtin/parse-markdown" },
    { qname = "builtin/text-metrics" },
    { qname = "builtin/text-similarity" },
    { qname = "builtin/text-search-corpus" },
    { qname = "builtin/split-text" },
    { qname = "builtin/text-grep" },
    { qname = "builtin/resolve-qnames-in-text" },
    { qname = "builtin/list-concat" },
    { qname = "builtin/list-unique-by" }
  ],
  field = "qname",
  equals = ${inputs.mention}
) @filter

_ <- tools/nonempty(items = ${hits.items}) @probe

return { ok = true }
```
