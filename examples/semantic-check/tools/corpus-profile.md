---
name: tools/corpus-profile
inputs:
  declarations: List<types/declaration-summary>
outputs:
  slices: List<types/corpus-slice>
imports:
  - builtin/list-concat
  - builtin/record-map
  - tools/corpus-profile-decl
---

## flow

Layer 2: profile markdown section bodies for all declarations.

```step
decl_rows <- foreach decl in ${inputs.declarations} {
  pack <- tools/corpus-profile-decl(decl = ${decl}) @decl
  return { slices = ${pack.slices} }
} @decls

layers <- builtin/record-map(items = ${decl_rows}, field = "slices") @pick
flat <- builtin/list-concat(lists = ${layers.values}) @flat

return { slices = ${flat.items} }
```
