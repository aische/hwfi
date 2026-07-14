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
---

## flow

True when any agent section in the declaration contains a directive tag.

```step
rows <- foreach section in ${inputs.decl.agent_sections} {
  hits <- builtin/record-filter(
    items = ${inputs.tags},
    where = {
      force = "directive",
      location = {
        file = ${inputs.decl.path},
        section = ${section}
      }
    }
  ) @hits

  pack <- try {
    markers <- foreach tag in ${hits.items} {
      return { hit = "yes" }
    } @markers

    _ <- tools/hit-nonempty(items = ${markers}) @count
    return { hit = "yes" }
  } catch {
    return { hit = "no" }
  } @branch

  return { hit = ${pack.hit} }
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
