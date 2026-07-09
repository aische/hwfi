---
kind: type-alias
name: types/task
definition: "Record<{ id: String, description: String, target: String }>"
---

A single implementation task in the shipping pipeline: stable `id`, human
`description`, and workspace-relative `target` path.
