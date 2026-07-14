---
name: tools/review-gate-prose-row
inputs:
  hint: types/finding
outputs:
  items: List<types/review-gate-item>
imports:
  - builtin/text-grep
  - tools/corpus-slice-id
  - tools/empty-review-gate-items
  - tools/markdown-section-body
  - tools/strings-equal
---

## flow

When a prose hint is a dead-reference warning, build one review-gate item.

```step
dead <- tools/strings-equal(
  left = ${inputs.hint.category},
  right = "dead_reference"
) @dead

pack <- if ${dead.equal} {
  warn <- tools/strings-equal(
    left = ${inputs.hint.severity},
    right = "warning"
  ) @warn

  branch <- if ${warn.equal} {
    inner <- try {
      body_pack <- tools/markdown-section-body(
        file = ${inputs.hint.location.file},
        section = ${inputs.hint.location.section}
      ) @body

      _ <- builtin/text-grep(
        text = ${body_pack.body},
        pattern = ".+"
      ) @nonempty

      id_pack <- tools/corpus-slice-id(location = ${inputs.hint.location}) @id

      return {
        items = [{
          location = ${inputs.hint.location},
          slice_id = ${id_pack.id},
          body = ${body_pack.body},
          gate_source = "dead_reference",
          review_task = "check_dead_reference",
          peer_location = { file = "", section = "" },
          peer_body = "",
          context = "unresolved_qname=${inputs.hint.evidence}",
          priority = 10
        }]
      }
    } catch {
      empty <- tools/empty-review-gate-items() @skip
      return { items = ${empty.items} }
    } @probe

    return { items = ${inner.items} }
  } else {
    empty <- tools/empty-review-gate-items() @skip
    return { items = ${empty.items} }
  } @warn_branch

  return { items = ${branch.items} }
} else {
  empty <- tools/empty-review-gate-items() @skip
  return { items = ${empty.items} }
} @dead_branch

return { items = ${pack.items} }
```
