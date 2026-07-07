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
- Revised decision after review: `hwfi` builds its own gateway map
  from `LLM.Providers.*` and its own key store from `--env-file`,
  `<project>/.env`, and process env (in that precedence). No chdir;
  no engine-default model catalog (every project ships one). Keys
  typed as `Secret Text` throughout. Startup validates provider–key
  linkage against the catalog (A12).
- Final decisions: binary `hwfi`, run dir `.hwfi/`, test `hspec`, md
  parser `commonmark-hs`, shared types under `types/*.md` in v1, model
  arg names a catalog entry, CLI structured inputs, `file:line:col`
  error format.
- Spec review pass (from temporary `issues.md`): step-key now includes a
  transitive callee fingerprint (fixes code-edit cache invalidation);
  strict `env` presence (no `Optional<T>` in v1); `TypeExpr` can
  reference aliases; added `builtin/llm-chat`; defined interpolation
  rendering; redesigned resume trace model (`Resumed` marker, no
  synthetic cached events, `ctx.trace` = full file parse); added `eval`
  error kind; tightened the `return` rule. Acceptance now A1–A16.

## Blockers

- None.

## Next up

See [TASKS.md](TASKS.md) → **Now (M1)**. Start with 1.1 (cabal init)
and 1.2 (`../llm-simple` local package).
