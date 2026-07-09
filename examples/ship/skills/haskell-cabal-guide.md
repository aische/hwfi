---
name: skills/haskell-cabal-guide
skill:
  kind: instruction
  summary: Initialize and build a Haskell Cabal package
  tags: [haskell, cabal, ghc]
---

# Haskell + Cabal guide

Use when the spec asks for a Haskell program, library, or executable.

## Scaffold

1. `cabal init -n --is-executable` (or `--is-library`) in the workspace root.
2. Edit `app/Main.hs` (or `src/`) with the requested modules.
3. Set `build-depends` in the `.cabal` file for any packages you import.

## Layout

- `app/Main.hs` — executable entry when using `cabal init` defaults.
- `src/` — library modules when building a library + exe.

## Verification

- `cabal build` must succeed before marking a task done.
- `cabal run` for executables; capture stdout when the spec requires output.
- `cabal test` when test suites are part of the spec.

## Tips

- Start minimal: one module, one `main`, then expand.
- Use `-Wall` in `ghc-options` when the spec mentions linting.
