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
  - tools/speech-act-tag-is-directive
---

## flow

True when any tag is a directive in the given agent section.

```step
rows <- foreach tag in ${inputs.tags} {
  probe <- tools/speech-act-tag-is-directive(
    tag = ${tag},
    file = ${inputs.file},
    section = ${inputs.section}
  ) @probe
  branch <- if ${probe.ok} {
    return { hit = "yes" }
  } else {
    return { hit = "no" }
  } @branch
} @rows

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
