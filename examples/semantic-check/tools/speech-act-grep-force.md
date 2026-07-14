---
name: tools/speech-act-grep-force
inputs:
  sentence: String
  location: types/location
  force: String
  pattern: String
  pattern_name: String
outputs:
  tags: List<types/speech-act-tag>
imports:
  - builtin/text-grep
  - tools/empty-speech-act-tags
  - tools/string-nonempty
---

## flow

Tag one sentence when a force-specific regex matches.

```step
pack <- try {
  grep <- builtin/text-grep(
    text = ${inputs.sentence},
    pattern = ${inputs.pattern}
  ) @grep

  _ <- tools/string-nonempty(items = ${grep.matches}) @hit

  return {
    tags = [{
      force = ${inputs.force},
      sentence = ${inputs.sentence},
      patterns = [${inputs.pattern_name}],
      location = ${inputs.location}
    }]
  }
} catch {
  empty <- tools/empty-speech-act-tags() @skip
  return { tags = ${empty.tags} }
} @probe

return { tags = ${pack.tags} }
```
