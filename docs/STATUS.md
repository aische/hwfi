# Status

Last updated: 2026-07-07

## Current focus

**M3 (type checker) is complete.** The engine now statically checks a
whole project and produces a `TypedProject` with resolved signatures,
per-step cacheability, and Merkle declaration fingerprints. `hwfi check`
is wired end-to-end and reports spec §9.1 diagnostics. Ready to start
**M4: runtime and built-in tools**.

## Done recently

- `Hwfi.Type`: resolved type representation (distinct from the surface
  `TypeExpr`), `structEq`, `assignable` (structural + `String`→`FileRef`
  subtyping), secret tagging, ambient `ctx`/`trace` field types.
- `Hwfi.Check.Error` (`TypeError`/`TypeErrorKind` → §9.1 diagnostics),
  `Hwfi.Check.Builtins` (`Callee` signatures for all `builtin/*`,
  `builtin/introspect` identity), `Hwfi.Check.Alias` (alias expansion +
  cycle detection).
- `Hwfi.Check.Graph`: direct call graph, import-cycle detection (SCC),
  and Merkle fingerprints computed over the acyclic graph.
- `Hwfi.Check.Expr` (reference/interpolation/`@self#slug` typing),
  `Hwfi.Check.Decl` (env building, arg checking, return rule, step
  cacheability), `Hwfi.Check.checkProject` orchestrator, `TypedProject`.
- `hwfi check` CLI wiring; catalog + project load + check with exit codes.
- Tests: 71 examples (unit specs + expected-error fixtures under
  `test/fixtures/check/`). `cabal build all`/`cabal test` green.

## Blockers

- None.

## Notes / decisions

- `assignable` adds one deliberate subtyping rule beyond `structEq`: a
  `String` is accepted where a `FileRef` is expected (literal paths).
- `Fingerprint` is a `newtype`, so the self-referential fingerprint map
  MUST be built with `Data.Map.Lazy.mapWithKey`; strict construction
  forces a callee's hash while the map is still being built and loops.
- YAML requires quoting type strings containing `:` (record types).

## Next up

See [TASKS.md](TASKS.md) → **M4: Runtime and built-in tools**. Start with
4.1 (linear step executor) and 4.2 (ambient `ctx` construction).
