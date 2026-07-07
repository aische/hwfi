# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

Grouped by milestone. Milestones are ordered; within a milestone, tasks are
roughly ordered but can be reshuffled.

## Now — M6+: Deferred features (spec §13)

M1–M5 are complete. The engine parses, type-checks, runs, persists,
resumes, and pretty-prints. Pick the next milestone from the backlog
below; control flow (6.1) is the natural next step.

## Backlog — M6+: Deferred, per spec §13

- [ ] 6.1 Control flow: `if`, `foreach`, `par`
- [ ] 6.2 Shell/exec built-in tool with sandbox policy
- [ ] 6.3 `builtin/eval-workflow` — parse+check+run a workflow produced
      at runtime (reuses M3 checker)
- [ ] 6.4 Cross-run trace reading built-in tool
- [ ] 6.5 Skill extraction from traces
- [ ] 6.6 `Bytes`-typed file I/O
- [ ] 6.7 `trace.jsonl` rotation
- [ ] 6.8 User-level key store (e.g. `$XDG_CONFIG_HOME/hwfi/.env`) as
      a lower-precedence source in §7.2

## Done

_Move items here temporarily, then archive to
`docs/log/archive/tasks-YYYY-MM.md`._

- [x] M1 Project skeleton (1.1–1.7): cabal project, `llm-simple` wiring,
      hspec suite, CLI stub, `project.json` parser, `KeyStore`, model
      catalog loader + provider-key validation. `cabal build`/`cabal test`
      green. (2026-07-07)
- [x] M2 Parsing and AST (2.1–2.9): AST + `Hwfi.Source`; markdown/
      frontmatter/type/expr/step/type-alias/section/project parsers on
      `commonmark-hs` + `megaparsec`; §9.1 diagnostics; 41 tests + parse
      fixtures. (2026-07-07)
- [x] M3 Type checker (3.1–3.12): `Hwfi.Type` (resolved types,
      `structEq`/`assignable`); `Hwfi.Check.{Error,Builtins,Alias,Graph,
      Expr,Decl}` + `checkProject`/`TypedProject`; alias + import cycle
      detection, `@self#slug` checks, `Secret<T>`/interpolation rules,
      return rule, step cacheability, Merkle fingerprints; `hwfi check`
      wired; 71 tests + expected-error fixtures. (2026-07-07)
- [x] M4 Runtime and built-in tools (4.1–4.9): `Hwfi.Runtime.{Value,Error,
      Trace,Workspace,Gateways,Context,Eval,Builtins,Executor}`; linear step
      interpreter with per-step ambient `ctx`, sandboxed workspace, all
      `builtin/*` tools (file I/O + `llm-generate`/`llm-chat`/`llm-gen-object`
      + `introspect`), sub-workflow calls, in-memory tracer; `hwfi run`
      wired; `examples/summarise/`; 102 tests (A3/A6/A9/A11 covered).
      (2026-07-07)
- [x] M5 Persistence, tracing, resume (5.1–5.9): `Hwfi.Runtime.{RunStore,
      StepKey}`; run dir + `run.json`; content-addressed step cache with
      §8.1 step-key; append-only `trace.jsonl` + `eventFromJson`; resume
      with `ctx.trace` reconstruction; secret redaction at the writer;
      `.hwfi/lock`; `hwfi resume`/`show`; 128 tests (A4/A7/A13/A15 +
      truncated-trace crash resume). (2026-07-07)
