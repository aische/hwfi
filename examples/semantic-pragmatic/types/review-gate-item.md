---
kind: type-alias
name: types/review-gate-item
definition: "Record<{ location: types/location, slice_id: String, body: String, gate_source: String, review_task: String, peer_location: types/location, peer_body: String, context: String, priority: Int }>"
---

Bounded slice selected for layer 3 pragmatic LLM review. `review_task` names the
review shape (`check_redundancy`, `check_contradiction`, `check_coverage_gap`,
`check_dead_reference`). Higher `priority` items are kept when capping the gate.
