# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

Grouped by milestone. Milestones are ordered; within a milestone, tasks are
roughly ordered but can be reshuffled.

## Now — carried-over optional items

M1–M8 are complete. The engine parses, type-checks, runs, persists, resumes,
pretty-prints, drives an agentic tool-use loop, modifies the workspace and runs
allowlisted commands, and now **branches and iterates** (`if`/`foreach`/`par`).
No milestone is currently in flight; the remaining near-term items are
performance/hardening, not new surface area:

- [ ] 8.g (Optional, carried over) serialise agent machine state to skip the
      replay re-walk on resume (§8.2.1) — performance only.

## Decide before v1 freeze

- [ ] **DEC-1 Identifier scoping in control-flow blocks (spec §4.2).** M8 ships a
      flat per-declaration id namespace (step binders / loop vars / construct
      `@id`s all unique, including across sibling `if` branches; no shadowing).
      Reconsider vs. branch/block-local scoping (sibling branches may reuse
      names; inner binds don't escape). Changing this later is a
      source-compatibility break. Owner: Daniel.

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
- [x] M8 control flow (8.1–8.3): `Statement` extended with `SIf`/`SLoop`
      (`Hwfi.Ast.Step`); `if`/`else`, `foreach`, `par(max = N)` parsing +
      reserved words; recursive checker (branch typing + mandatory `else`,
      `List<T>` iteration binding, `List<U>` loop result, no-shadow, flat
      per-declaration id namespace); callee/fingerprint/exec-policy recursion
      through blocks; `if-branch`/`loop-start`/`loop-iter`/`loop-end` trace
      events + `MVar`-serialised tracer for `par`; executor `execIf`/`execLoop`
      (sequential `foreach`, bounded order-preserving `par`) with a scope
      prefix folded into step-keys for per-iteration resume; value-producing
      block semantics; `examples/control-flow`; 207 tests incl.
      `Hwfi.Runtime.ControlFlowSpec` (execution, ordering, `par` concurrency,
      resume durability, checker rejections). (2026-07-08)
