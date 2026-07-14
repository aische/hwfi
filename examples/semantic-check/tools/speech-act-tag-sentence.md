---
name: tools/speech-act-tag-sentence
inputs:
  sentence: String
  location: types/location
outputs:
  tags: List<types/speech-act-tag>
imports:
  - builtin/text-grep
  - tools/empty-speech-act-tags
---

## flow

Apply all illocutionary force heuristics to one sentence.

```step
pack <- try {
  grep <- builtin/text-grep(
    text = ${inputs.sentence},
    location = ${inputs.location},
    patterns = [
      {
        name = "directive",
        pattern = "(?i)\\b(must|always|never|shall|do not|ensure|verify|required|write|inspect|fix|re-run|keep)\\b",
        force = "directive"
      },
      {
        name = "assertive",
        pattern = "(?i)\\b(is|are|contains|will be|the workspace|the project)\\b",
        force = "assertive"
      },
      {
        name = "commissive",
        pattern = "(?i)\\b(you will|I will|we will|I'll|you'll|I shall)\\b",
        force = "commissive"
      },
      {
        name = "declarative",
        pattern = "(?i)\\b(consider yourself|authorized|you are the|your role is)\\b",
        force = "declarative"
      }
    ]
  ) @grep

  return { tags = ${grep.tags} }
} catch {
  empty <- tools/empty-speech-act-tags() @skip
  return { tags = ${empty.tags} }
} @probe

return { tags = ${pack.tags} }
```
