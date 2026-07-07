---
name: tools/headline
inputs:
  brief: types/doc-brief
outputs:
  line: String
---

## flow

Render a one-line headline from a structured `types/doc-brief` record. Because
`brief` has a statically-known record type, the field accesses `${brief.title}`,
`${brief.audience}`, and `${brief.key_points}` are all checked at `hwfi check`
(spec §5.6.7). The `key_points` list is a `List<String>`; interpolating it into
the string renders it as compact canonical JSON (spec §3.2.1).

```step
return {
  line = "Brief \"${inputs.brief.title}\" for ${inputs.brief.audience} — key points: ${inputs.brief.key_points}"
}
```
