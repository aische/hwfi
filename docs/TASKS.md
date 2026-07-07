# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

Grouped by milestone. Milestones are ordered; within a milestone, tasks are
roughly ordered but can be reshuffled.

## Now — M8: control flow (`if`/`foreach`/`par`, spec §13)

M1–M7 are complete. The engine parses, type-checks, runs, persists,
resumes, pretty-prints, drives an agentic tool-use loop (`builtin/llm-agent`),
and can now **modify the workspace and run allowlisted commands** (mutation +
`exec` builtins). The next milestone adds **control flow** so workflows can
branch and iterate. Decision: build these on the reified state machine that
already backs the M6 agent loop rather than a bespoke evaluator, so caching,
tracing, and resume semantics (§8.1/§8.2) stay uniform.

Ordered so each item is independently testable:

- [ ] 8.1 `if`/`else` conditional step (§13): parser + AST, checker (branch
      typing, cacheability), executor + trace events.
- [ ] 8.2 `foreach` iteration over a `List<_>` (§13): binding semantics,
      per-iteration step-keys for resume, trace nesting.
- [ ] 8.3 `par` concurrent fan-out (§13): bounded concurrency, deterministic
      result ordering, trace interleaving, resume.
- [ ] 8.g (Optional, carried over) serialise agent machine state to skip the
      replay re-walk on resume (§8.2.1) — performance only.

## Backlog — M9+: Deferred, per spec §13

- [ ] 9.1 OS-level `exec` isolation (namespaces/seccomp/cgroups) beyond the
      allowlist + empty-env model (§7.5)
- [ ] 9.2 `builtin/eval-workflow` — parse+check+run a workflow produced
      at runtime (reuses M3 checker)
- [ ] 9.3 Cross-run trace reading built-in tool
- [ ] 9.4 Skill extraction from traces
- [ ] 9.5 `Bytes`-typed file I/O
- [ ] 9.6 `trace.jsonl` rotation
- [ ] 9.7 User-level key store (e.g. `$XDG_CONFIG_HOME/hwfi/.env`) as
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
- [x] M6 LLM tool-use (6.a–6.f): `Hwfi.Runtime.{Schema,Agent}`;
      `builtin/llm-agent` + `builtin/llm-agent-object` agentic loop over a
      reified round/tool-call machine; `Type -> JSON Schema` + agent
      eligibility; bespoke agent type-check (`checkAgentCall`, cycle-safe
      `reachesIntrospect`, non-cacheable); agent trace events + `hwfi show`
      rendering; intra-step content-addressed model/tool-call caching reused
      on resume (§8.2.1); `examples/research` agent workflows; 152 tests
      (A17–A21). 6.g (state serialisation) deferred as optional. (2026-07-07)
- [x] M7 mutation + exec tools (7.1–7.6): `Hwfi.Runtime.{Glob,Exec}`;
      navigation (`read-file-slice`/`find-files`/`grep`) + mutation
      (`edit-file`/`move-file`/`copy-file`/`remove-file`/`make-dir`/
      `remove-dir`) as native builtins over the sandboxed `Workspace`;
      `builtin/exec` via `typed-process` (argv-only, allowlist + env +
      timeout + output caps from `project.json.exec`, non-zero exit as
      value); `ExecPolicy` parsing + `hwfi check` rejection (A24); extended
      `file-io`/`exec` trace events + `hwfi show`; `examples/coding`
      (scripted + agentic); 188 tests (A22–A26 incl. durable-workspace
      resume and an end-to-end agent coding loop). (2026-07-07)
