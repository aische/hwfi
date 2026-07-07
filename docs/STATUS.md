# Status

Last updated: 2026-07-07

## Current focus

**M1 (project skeleton) is complete.** The cabal project builds, the
`llm-simple` local dependency is wired, the CLI parses all four commands,
and the runtime foundations (key store, model catalog loader, project
manifest) are implemented and unit-tested. Ready to start **M2: parsing
and AST**.

## Done recently

- Cabal project (`hwfi.cabal`, `cabal.project`, GHC2021): library +
  `hwfi` executable + `hspec` test-suite. `cabal build` and `cabal test`
  both green (14 examples).
- `Hwfi.Compat`: curated re-exports of the consumed `llm-simple` surface
  (`LLM.Generate`, `LLM.Providers.OpenAI`, `LLM.Load.ModelCatalog`);
  confirms 1.2 wiring compiles.
- `Hwfi.Cli`: `optparse-applicative` parser for `check`/`run`/`resume`/
  `show` incl. `--workspace`, `--env-file`, repeatable `--input k=v|k=@f`,
  `--input-json`, `--entry`. Commands are stubs (exit 2, "not implemented").
- `Hwfi.Project.Manifest`: `project.json` parser (strict fields, optional
  `env` → `[]`) + `validateEnvPresence` for strict env presence (A14).
- `Hwfi.Runtime.Secret`: opaque `Secret a` with redacting `Show`.
- `Hwfi.Runtime.Provider`: closed provider sum type + env-var mapping.
- `Hwfi.Runtime.KeyStore`: `.env` parsing via `Configuration.Dotenv.parseFile`,
  precedence `--env-file` > `<project>/.env` > process env, no process-env
  injection. Keys typed `Secret Text`.
- `Hwfi.Runtime.ModelCatalog`: required `model-catalog.json` loader wrapping
  `loadModelCatalog`; `validateProviderKeys` for A12 (spec-verbatim error).

## Blockers

- None.

## Next up

See [TASKS.md](TASKS.md) → **M2: Parsing and AST**. Start with 2.1
(`commonmark-hs` markdown splitting) and 2.2 (core AST modules).
Note: `commonmark-hs` is not yet in the local cabal cache; first M2 build
will need network to fetch it.
