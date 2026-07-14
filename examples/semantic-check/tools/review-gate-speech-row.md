---
name: tools/review-gate-speech-row
inputs:
  hint: types/speech-act-hint
  slices: List<types/corpus-slice>
outputs:
  items: List<types/review-gate-item>
imports:
  - builtin/record-filter
  - builtin/text-grep
  - tools/corpus-slice-by-id
  - tools/corpus-slice-id
  - tools/empty-review-gate-items
  - tools/hit-nonempty
  - tools/string-nonempty
---

## flow

When a speech-act hint is gate-worthy, build one review-gate item for its slice.

```step
pack <- try {
  gap <- builtin/record-filter(
    items = [{ category = ${inputs.hint.category} }],
    where = { category = "coverage_gap" }
  ) @gap

  gate <- try {
    rows <- foreach row in ${gap.items} {
      return { hit = "yes" }
    } @gap_rows

    _ <- tools/hit-nonempty(items = ${rows}) @gap_hit

    return { gate = true, gate_source = "speech_act_mismatch" }
  } catch {
    amb <- builtin/record-filter(
      items = [{ category = ${inputs.hint.category} }],
      where = { category = "ambiguity" }
    ) @amb

    inner <- try {
      amb_rows <- foreach row in ${amb.items} {
        return { hit = "yes" }
      } @amb_rows

      _ <- tools/hit-nonempty(items = ${amb_rows}) @amb_hit

      probe <- try {
        grep <- builtin/text-grep(
          text = ${inputs.hint.claim},
          pattern = "Directive sentence lacks"
        ) @grep

        _ <- tools/string-nonempty(items = ${grep.matches}) @grep_hit

        return { gate = true }
      } catch {
        return { gate = false }
      } @probe

      branch <- if ${probe.gate} {
        return { gate = true, gate_source = "speech_act_directive" }
      } else {
        return { gate = false, gate_source = "" }
      } @branch

      return { gate = ${branch.gate}, gate_source = ${branch.gate_source} }
    } catch {
      return { gate = false, gate_source = "" }
    } @amb_probe

    branch <- if ${inner.gate} {
      return { gate = true, gate_source = ${inner.gate_source} }
    } else {
      return { gate = false, gate_source = "" }
    } @amb_branch

    return { gate = ${branch.gate}, gate_source = ${branch.gate_source} }
  } @gate_pick

  branch <- if ${gate.gate} {
    id <- tools/corpus-slice-id(location = ${inputs.hint.location}) @id

    slice <- tools/corpus-slice-by-id(
      id = ${id.id},
      slices = ${inputs.slices}
    ) @slice

    return {
      items = [{
        location = ${inputs.hint.location},
        slice_id = ${slice.slice.id},
        body = ${slice.slice.body},
        gate_source = ${gate.gate_source},
        trigger_claim = ${inputs.hint.claim}
      }]
    }
  } else {
    empty <- tools/empty-review-gate-items() @skip
    return { items = ${empty.items} }
  } @build

  return { items = ${branch.items} }
} catch {
  empty <- tools/empty-review-gate-items() @skip
  return { items = ${empty.items} }
} @probe

return { items = ${pack.items} }
```
