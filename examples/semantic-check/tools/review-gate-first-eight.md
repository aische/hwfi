---
name: tools/review-gate-first-eight
inputs:
  items: List<types/review-gate-item>
outputs:
  items: List<types/review-gate-item>
imports:
  - builtin/list-concat
  - tools/empty-review-gate-items
---

## flow

Keep at most eight review-gate items (bounded LLM cost).

```step
row0 <- try {
  return { items = [${inputs.items[0]}] }
} catch {
  empty <- tools/empty-review-gate-items() @e0
  return { items = ${empty.items} }
} @i0

row1 <- try {
  return { items = [${inputs.items[1]}] }
} catch {
  empty <- tools/empty-review-gate-items() @e1
  return { items = ${empty.items} }
} @i1

row2 <- try {
  return { items = [${inputs.items[2]}] }
} catch {
  empty <- tools/empty-review-gate-items() @e2
  return { items = ${empty.items} }
} @i2

row3 <- try {
  return { items = [${inputs.items[3]}] }
} catch {
  empty <- tools/empty-review-gate-items() @e3
  return { items = ${empty.items} }
} @i3

row4 <- try {
  return { items = [${inputs.items[4]}] }
} catch {
  empty <- tools/empty-review-gate-items() @e4
  return { items = ${empty.items} }
} @i4

row5 <- try {
  return { items = [${inputs.items[5]}] }
} catch {
  empty <- tools/empty-review-gate-items() @e5
  return { items = ${empty.items} }
} @i5

row6 <- try {
  return { items = [${inputs.items[6]}] }
} catch {
  empty <- tools/empty-review-gate-items() @e6
  return { items = ${empty.items} }
} @i6

row7 <- try {
  return { items = [${inputs.items[7]}] }
} catch {
  empty <- tools/empty-review-gate-items() @e7
  return { items = ${empty.items} }
} @i7

merged <- builtin/list-concat(lists = [
  ${row0.items},
  ${row1.items},
  ${row2.items},
  ${row3.items},
  ${row4.items},
  ${row5.items},
  ${row6.items},
  ${row7.items}
]) @merged

return { items = ${merged.items} }
```
