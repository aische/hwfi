# Status

Last updated: 2026-07-07

## Current focus

**M2 (parsing and AST) is complete.** The engine now parses a whole
project — frontmatter signatures, the step DSL, expressions, type
expressions, type aliases, and markdown sections — into a typed AST, with
spec §9.1 diagnostics. Ready to start **M3: type checker**.

## Done recently

- AST modules: `Hwfi.Ast.{Name,Type,Expr,Step,Workflow,Tool,TypeAlias,Project}`
  and `Hwfi.Source` (positions, spans, §9.1 diagnostic renderer).
- `Hwfi.Parse.Markdown` on `commonmark-hs`: custom `IsInline`/`IsBlock`
  instances capture headings and fenced `step` blocks with absolute source
  lines; frontmatter is blanked (not removed) to keep positions aligned.
- `Hwfi.Parse.Lexer`: shared megaparsec lexer with two space consumers
  (`sc` intra-statement, `scn` inside brackets); `runParserAt` for
  file-absolute positions; error-bundle → `[Diagnostic]`.
- Parsers: `Type` (incl. `QName` alias refs), `Expr` (bare-ref vs
  in-string interpolation per §3.2.1, short/long strings, escapes),
  `Step` (binders, `@id`, discard rule, `return`, comments).
- `Hwfi.Parse.Frontmatter` (YAML → `Signature`, TypeExpr sub-parser),
  `Hwfi.Parse.TypeAlias`, `Hwfi.Parse.Section` (slug + `@self#slug` raw
  content), `Hwfi.Parse.Project` (walks dirs, classifies by kind, builds
  `Map QName Declaration`).
- Tests: 41 examples (parsers, sections, §9.1 renderer, fixture projects
  under `test/fixtures/parse/`). `cabal build`/`cabal test` green.

## Blockers

- None.

## Notes / decisions

- YAML requires quoting type strings that contain `:` (record types),
  e.g. `definition: "Record<{ role: String }>"`. Spec §2.1/§3.4 examples
  show them unquoted; treat quoting as required in real files.
- `Tool` mirrors `Workflow` structurally in v1 (distinct type, shared
  `Signature`/`Section`). `DeclPrompt` is supported (kind: prompt) though
  v1 has no cross-file prompt reference.

## Next up

See [TASKS.md](TASKS.md) → **M3: Type checker**. Start with 3.1 (type
representation) and 3.2 (alias resolution + cycle detection).
