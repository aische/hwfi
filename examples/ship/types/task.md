---
kind: type-alias
name: types/task
definition: "Record<{ id: String, description: String, verify_command: String }>"
---

A single implementation task from the planner: stable `id`, human `description`,
and an optional shell one-liner the builder can run via `builtin/exec` to verify
the task (`verify_command` may be empty when not applicable).
