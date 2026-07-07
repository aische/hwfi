---
kind: type-alias
name: types/doc-brief
definition: "Record<{ title: String, audience: String, key_points: List<String> }>"
---

A structured brief describing a document under review: its `title`, the intended
`audience`, and a list of `key_points`. Used as a tool input type so field
access is statically checked (spec §5.6.7).
