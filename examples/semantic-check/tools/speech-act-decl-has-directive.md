---
name: tools/speech-act-decl-has-directive
inputs:
  decl: types/declaration-summary
  tags: List<types/speech-act-tag>
outputs:
  ok: Bool
imports:
  - builtin/record-filter
  - tools/hit-nonempty
  - tools/speech-act-has-directive-in-section
---

## flow

True when any agent section in the declaration contains a directive tag.

```step
rows <- foreach section in ${inputs.decl.agent_sections} {
  probe <- tools/speech-act-has-directive-in-section(
    tags = ${inputs.tags},
    file = ${inputs.decl.path},
    section = ${section}
  ) @probe
  branch <- if ${probe.ok} {
    return { hit = "yes" }
  } else {
    return { hit = "no" }
  } @branch
} @sections

pack <- try {
  hits <- builtin/record-filter(
    items = ${rows},
    field = "hit",
    equals = "yes"
  ) @hits

  _ <- tools/hit-nonempty(items = ${hits.items}) @count

  return { ok = true }
} catch {
  return { ok = false }
} @probe

return { ok = ${pack.ok} }
```
