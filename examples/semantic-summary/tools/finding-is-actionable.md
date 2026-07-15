---
name: tools/finding-is-actionable
inputs:
  finding: Json
outputs:
  actionable: Bool
imports:
  - builtin/text-grep
  - tools/finding-as-text
  - tools/string-nonempty
---

## flow

True when a finding severity is `error` or `warning`.

```step
text <- tools/finding-as-text(finding = ${inputs.finding}) @text

pack <- try {
  err <- builtin/text-grep(
    text = ${text.text},
    pattern = "\"severity\":\"error\""
  ) @err

  _ <- tools/string-nonempty(items = ${err.matches}) @err_hit

  return { actionable = true }
} catch {
  inner <- try {
    warn <- builtin/text-grep(
      text = ${text.text},
      pattern = "\"severity\":\"warning\""
    ) @warn

    _ <- tools/string-nonempty(items = ${warn.matches}) @warn_hit

    return { actionable = true }
  } catch {
    return { actionable = false }
  } @warn_probe

  return { actionable = ${inner.actionable} }
} @probe

return { actionable = ${pack.actionable} }
```
