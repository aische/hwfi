# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

Grouped by milestone. Milestones are ordered; within a milestone, tasks are
roughly ordered but can be reshuffled.

## Later — optional items

M1–M9 complete. Near-term work is optional / perf:

- [ ] 9.1 OS-level `exec` isolation (namespaces/seccomp/cgroups) beyond the
      allowlist + empty-env model (§7.5)
- [ ] 9.3 Cross-run trace reading built-in tool
- [ ] 9.4 Skill extraction from traces
- [ ] 9.5 `Bytes`-typed file I/O
- [ ] 9.6 `trace.jsonl` rotation

## Done

_Move items here temporarily, then archive to
`docs/log/archive/tasks-YYYY-MM.md`._

- [x] 9.2 `builtin/eval-workflow` (§6.4, 2026-07-09): parse+check+run dynamic
      source; `{ ok, outputs, errors }` recoverable failures; non-cacheable;
      agent-eligible; tests A34/A35. 249 tests green.
- [x] A32 integration test (2026-07-09): `while` predicate with
      `builtin/llm-agent` replays pinned decision on resume without
      re-invoking the model (`ControlFlowSpec`; 245 tests).
- [x] 8.g (Optional) serialise agent machine state to skip the replay re-walk
      on resume (§8.2.1, 2026-07-09): checkpoint `{messages, next_round}`
      under agent step-key; reload on resume; cleared on success; 244 tests.
- [x] M9 `while` loops (§4.3, 2026-07-09): `WhileStmt` AST + parser;
      checker (predicate `continue`/`reason`, `carry` scoping, callee graph);
      `execWhile` with `#i/p/` / `#i/b/` scopes and decision-key resume;
      `while-pred` trace + optional `loop-start.count`; tests A30/A31/A33;
      parser test. 243 tests green.
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
- [x] **DEC-1** Block-local identifier scoping (spec §4.2): `@id`s unique per
      block; sibling branches/loops may reuse names; no shadowing outward.
      Checker + tests + `examples/control-flow` updated. (2026-07-08)
- [x] H1 Runtime hardening (H1.1–H1.5, code review 2026-07-08): threaded RTS
      (§7.6); symlink sandbox containment (§7.1); model-catalog fingerprint in
      one-shot LLM step-keys (§8.1); sub-workflow scope threading (§4.1); crash
      handler with `PhaseCrashed` + `run-end` (`crashed`) (§8.2). Source:
      [code-issues.md](code-issues.md). (2026-07-08)
- [x] 9.7 (Optional) user-level key store (§7.2): `$XDG_CONFIG_HOME/hwfi/.env`
      as lowest-precedence provider-key source (below process env);
      `KeyStoreSpec` precedence tests. (2026-07-08)
- [x] 9.8 (Optional) usage and cost accounting (§8.4): per-call `cost_usd`
      on `llm-call`; run-scoped running total in `run.json` and
      `ctx.run.usage`; optional `project.json` `budget.max_cost_usd`;
      cached/resumed provider calls bill $0; `hwfi show` usage summary.
      `Hwfi.Runtime.{RunUsage,Usage}`; tests A27–A29. (2026-07-08)
- [x] M8 control flow (8.1–8.3): `Statement` extended with `SIf`/`SLoop`
      (`Hwfi.Ast.Step`); `if`/`else`, `foreach`, `par(max = N)` parsing +
      reserved words; recursive checker (branch typing + mandatory `else`,
      `List<T>` iteration binding, `List<U>` loop result, no-shadow,
      per-block id namespace); callee/fingerprint/exec-policy recursion
      through blocks; `if-branch`/`loop-start`/`loop-iter`/`loop-end` trace
      events + `MVar`-serialised tracer for `par`; executor `execIf`/`execLoop`
      (sequential `foreach`, bounded order-preserving `par`) with a scope
      prefix folded into step-keys for per-iteration resume; value-producing
      block semantics; `examples/control-flow`; 210 tests incl.
      `Hwfi.Runtime.ControlFlowSpec` (execution, ordering, `par` concurrency,
      resume durability, checker rejections). (2026-07-08)
