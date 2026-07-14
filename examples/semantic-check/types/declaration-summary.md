---
kind: type-alias
name: types/declaration-summary
definition: "Record<{ qname: String, kind: String, path: String, inputs: Json, outputs: Json, imports: List<String>, agent_sections: List<String>, steps: List<types/step-summary> }>"
---

Declaration metadata exported by `builtin/check-project`.
