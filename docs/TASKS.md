# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

Grouped by milestone. Milestones are ordered; within a milestone, tasks are
roughly ordered but can be reshuffled.

## Now — M6: LLM tool-use (spec §6.1)

M1–M5 are complete. The engine parses, type-checks, runs, persists,
resumes, and pretty-prints. The next milestone is **agentic tool-use**
(`builtin/llm-agent`), now specified in spec §6.1 / §8.2.1 / §8.3 and
detailed in [tool-use.md](tool-use.md). Start with the schema translation
(6.a) and the evaluator refactor (6.b), which control flow (M7) also reuses.

## Backlog — M6: LLM tool-use (spec §6.1)

Agentic function calling: `builtin/llm-agent` / `builtin/llm-agent-object`.
Design in [tool-use.md](tool-use.md); normative behaviour now in spec §6.1,
§8.2.1, §8.3. Ordered so each item is independently testable (tool-use.md §6).

- [ ] 6.a Schema translation `Type -> JSON Schema`, with secret/ref/`Bytes`
      rejection (§6.1.1). Pure, unit-testable; reused for tool params and
      the `submit` schema.
- [ ] 6.b Evaluator refactor: express step execution as a reified
      step/continuation machine over `RValue` (modelled on
      `../llm-workflow`, without `unsafeCoerce`) so tools, sub-workflows,
      and later control flow share one loop. Foundational.
- [ ] 6.c `builtin/llm-agent` driving that machine over `LLM.Generate`,
      model tool calls reified as nested executor steps (§6.1.2);
      black-box non-cacheable (§8.1). Type-check + graph fingerprint.
- [ ] 6.d `builtin/llm-agent-object` + terminating `submit` tool for typed
      output (§6.1.3); subsumes `builtin/llm-gen-object` as the zero-tool
      case.
- [ ] 6.e Trace events `agent-round-start/-tool-call/-tool-result/-round-end`
      with redaction (§8.3), `hwfi show` rendering, `eventFromJson`
      round-trip.
- [ ] 6.f Intra-step content-addressed caching (§8.2.1) — *required*:
      sub-key each model call and tool call under the agent step-key, reuse
      `RunStore`, consult on resume. Hardest and most important item.
- [ ] 6.g (Optional, later) serialise machine state to skip the replay
      re-walk (§8.2.1) — performance only.

## Backlog — M7+: Deferred, per spec §13

- [ ] 7.1 Control flow: `if`, `foreach`, `par` (shares the M6 evaluator)
- [ ] 7.2 Shell/exec built-in tool with sandbox policy
- [ ] 7.3 `builtin/eval-workflow` — parse+check+run a workflow produced
      at runtime (reuses M3 checker)
- [ ] 7.4 Cross-run trace reading built-in tool
- [ ] 7.5 Skill extraction from traces
- [ ] 7.6 `Bytes`-typed file I/O
- [ ] 7.7 `trace.jsonl` rotation
- [ ] 7.8 User-level key store (e.g. `$XDG_CONFIG_HOME/hwfi/.env`) as
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
