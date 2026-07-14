---
name: tools/speech-act-tag-sentence
inputs:
  sentence: String
  location: types/location
outputs:
  tags: List<types/speech-act-tag>
imports:
  - builtin/list-concat
  - tools/speech-act-grep-force
---

## flow

Apply all illocutionary force heuristics to one sentence.

```step
directive <- tools/speech-act-grep-force(
  sentence = ${inputs.sentence},
  location = ${inputs.location},
  force = "directive",
  pattern = "(?i)\\b(must|always|never|shall|do not|ensure|verify|required|write|inspect|fix|re-run|keep)\\b",
  pattern_name = "directive"
) @directive

assertive <- tools/speech-act-grep-force(
  sentence = ${inputs.sentence},
  location = ${inputs.location},
  force = "assertive",
  pattern = "(?i)\\b(is|are|contains|will be|the workspace|the project)\\b",
  pattern_name = "assertive"
) @assertive

commissive <- tools/speech-act-grep-force(
  sentence = ${inputs.sentence},
  location = ${inputs.location},
  force = "commissive",
  pattern = "(?i)\\b(you will|I will|we will|I'll|you'll|I shall)\\b",
  pattern_name = "commissive"
) @commissive

declarative <- tools/speech-act-grep-force(
  sentence = ${inputs.sentence},
  location = ${inputs.location},
  force = "declarative",
  pattern = "(?i)\\b(consider yourself|authorized|you are the|your role is)\\b",
  pattern_name = "declarative"
) @declarative

merged <- builtin/list-concat(lists = [
  ${directive.tags},
  ${assertive.tags},
  ${commissive.tags},
  ${declarative.tags}
]) @merged

return { tags = ${merged.items} }
```
