---
kind: type-alias
name: types/step-summary
definition: "Record<{ step_id: String, target: String, agent_tools: List<String>, interpolations: List<String>, bare_qnames: List<String> }>"
---

Per-step metadata exported by `builtin/check-project`.
