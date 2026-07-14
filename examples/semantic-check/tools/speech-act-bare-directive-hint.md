---
name: tools/speech-act-bare-directive-hint
inputs:
  tag: types/speech-act-tag
outputs:
  hints: List<types/speech-act-hint>
imports:
  - builtin/record-filter
  - builtin/text-grep
  - tools/empty-speech-act-hints
  - tools/hit-nonempty
  - tools/string-nonempty
---

## flow

Flag directive sentences that lack an explicit condition (if/when/unless).

```step
directives <- builtin/record-filter(
  items = [${inputs.tag}],
  where = { force = "directive" }
) @directives

pack <- try {
  rows <- foreach tag in ${directives.items} {
    return { hit = "yes" }
  } @rows

  _ <- tools/hit-nonempty(items = ${rows}) @force_hit

  inner <- try {
    grep <- builtin/text-grep(
      text = ${inputs.tag.sentence},
      pattern = "(?i)\\b(if|when|unless|only if|provided that)\\b"
    ) @grep

    _ <- tools/string-nonempty(items = ${grep.matches}) @cond

    empty <- tools/empty-speech-act-hints() @skip
    return { hints = ${empty.hints} }
  } catch {
    return {
      hints = [{
        severity = "info",
        category = "ambiguity",
        location = ${inputs.tag.location},
        claim = "Directive sentence lacks an explicit condition",
        evidence = ${inputs.tag.sentence},
        suggestion = "Add a verifiable when/unless guard or cite a checkable precondition",
        force = "directive",
        step_id = ""
      }]
    }
  } @probe

  return { hints = ${inner.hints} }
} catch {
  empty <- tools/empty-speech-act-hints() @skip
  return { hints = ${empty.hints} }
} @branch

return { hints = ${pack.hints} }
```
