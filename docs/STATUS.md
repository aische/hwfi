# Status

Last updated: 2026-07-07

## Current focus

Spec v1 is complete: all `[open]` markers resolved, grammar and trace
schema pinned, `llm-simple` integration path verified against source.
Ready to start **M1: project skeleton**.

## Done recently

- Concretised `docs/spec.md` from `idea.md`: layout, syntax, type system,
  built-in tools, sandbox, persistence, CLI, acceptance A1–A11.
- Locked step DSL and expression grammar (§3.4 EBNF); locked trace event
  schema with ordering invariants (§8.3).
- Ambient typed `Context` (`workspace`, `run`, `self`, `inputs`, `trace`,
  `env`) + `builtin/introspect` escape hatch + `Secret<T>` with trace
  redaction + non-cacheable classification for volatile-ctx steps.
- Read `llm-simple` `Load` module; confirmed `.env`-based key flow.
  Decision: `hwfi` chdirs to project dir at startup; keys never flow
  through `ctx.env`.
- Final decisions: binary `hwfi`, run dir `.hwfi/`, test `hspec`, md
  parser `commonmark-hs`, shared types under `types/*.md` in v1, model
  arg names a catalog entry, CLI structured inputs, `file:line:col`
  error format.

## Blockers

- None.

## Next up

See [TASKS.md](TASKS.md) → **Now (M1)**. Start with 1.1 (cabal init)
and 1.2 (`../llm-simple` local package).
