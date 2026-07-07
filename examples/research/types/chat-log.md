---
kind: type-alias
name: types/chat-log
definition: "List<types/message>"
---

An ordered chat history. This alias references another alias (`types/message`),
exercising nested alias resolution during type-checking (spec §2.1, A10).
