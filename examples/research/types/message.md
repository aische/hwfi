---
kind: type-alias
name: types/message
definition: "Record<{ role: String, content: String }>"
---

A single chat message: a `role` (`"user"`, `"assistant"`, or `"tool"`) and its
textual `content`. Shared by every workflow that talks to `builtin/llm-chat`.
