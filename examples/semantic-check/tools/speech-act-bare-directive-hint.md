---
name: tools/speech-act-bare-directive-hint
inputs:
  tag: types/speech-act-tag
outputs:
  hints: List<types/speech-act-hint>
imports:
  - builtin/text-grep
  - tools/empty-speech-act-hints
  - tools/string-nonempty
  - tools/strings-equal
---

## flow

Flag directive sentences that lack an explicit condition (if/when/unless).

```step
force <- tools/strings-equal(
  left = ${inputs.tag.force},
  right = "directive"
) @force_chk

pack <- if ${force.equal} {
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
} else {
  empty <- tools/empty-speech-act-hints() @skip
  return { hints = ${empty.hints} }
} @branch

return { hints = ${pack.hints} }
```
