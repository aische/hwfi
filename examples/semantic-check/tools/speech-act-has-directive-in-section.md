---
name: tools/speech-act-has-directive-in-section
inputs:
  tags: List<types/speech-act-tag>
  file: String
  section: String
outputs:
  ok: Bool
imports:
  - builtin/record-filter
  - tools/hit-nonempty
---

## flow

True when any tag is a directive in the given agent section.

```step
hits <- builtin/record-filter(
  items = ${inputs.tags},
  where = {
    force = "directive",
    location = {
      file = ${inputs.file},
      section = ${inputs.section}
    }
  }
) @hits

rows <- foreach tag in ${hits.items} {
  return { hit = "yes" }
} @rows

pack <- try {
  _ <- tools/hit-nonempty(items = ${rows}) @count
  return { ok = true }
} catch {
  return { ok = false }
} @probe

return { ok = ${pack.ok} }
```
