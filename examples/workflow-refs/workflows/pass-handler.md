---
name: workflows/pass-handler
inputs:
  handler: "ToolRef<Record<{ q: String }>, Record<{ text: String }>>"
  q: String
outputs:
  note: String
imports:
  - tools/search
---

## overview

Pass a `ToolRef` as a workflow input (fingerprint-aware step-keys). This
workflow forwards the ref to a downstream step argument rather than invoking
it — higher-order step calls require a top-level bind name (see
docs/workflow-refs.md).

```step
meta <- tools/search(q = "handler registered") @meta
return {
  note = "handler ref accepted; caller chose ${meta.text} — invoke via static qname or agent tools"
}
```
