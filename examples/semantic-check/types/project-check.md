---
kind: type-alias
name: types/project-check
definition: "Record<{ ok: Bool, errors: List<String>, warnings: List<String>, declarations: List<types/declaration-summary>, call_graph: Json, error: String }>"
---

Recoverable result shape of `builtin/check-project`.
