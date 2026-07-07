# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

Grouped by milestone. Milestones are ordered; within a milestone, tasks are
roughly ordered but can be reshuffled.

## Now — M7: mutation + exec tools (coding workflows, spec §6.2/§6.3/§7.5)

M1–M6 are complete. The engine parses, type-checks, runs, persists,
resumes, pretty-prints, and drives an agentic tool-use loop
(`builtin/llm-agent`). The next milestone makes workflows and agents able
to **modify the workspace and run commands** — the prerequisite for
coding workflows. Decision (spec §6.2, tool-use.md §8): implement these as
**native `builtin/*` tools** over `Hwfi.Runtime.Workspace`, not by wrapping
`llm-simple`'s `LLM.Tools.*`/`TypedTool`, so there is one sandbox, one
trace stream, one fingerprint/cache scheme. Pure algorithms (glob, regex,
binary detection, find/replace) may be ported.

Ordered so each item is independently testable:

- [ ] 7.1 Read/navigation builtins: `read-file-slice`, `find-files`,
      `grep` (§6.2). Extend `Check.Builtins` signatures, `Runtime.Builtins`
      dispatch, and the `file-io` trace op enum (§8.3.2).
- [ ] 7.2 Mutation builtins: `edit-file` (with `expect` guard, A23),
      `move-file`, `copy-file`, `remove-file`, `make-dir`, `remove-dir`
      (§6.2). All through the `Workspace` guard (A22); cacheable; durable-
      workspace resume (A25).
- [ ] 7.3 `builtin/exec` (§6.3, §7.5): `typed-process` child in the
      workspace, argv (no shell), allowlist + env + timeout + output caps
      from `project.json.exec`; `exec` trace event; non-zero exit as value
      (A24). Cacheable + replayed on resume (A25).
- [ ] 7.4 `project.json` `exec` policy parsing (§2) + `hwfi check`
      rejection of un-allowlisted / policy-less `exec` calls (A24).
- [ ] 7.5 Agent eligibility: confirm mutation/exec builtins are advertisable
      as agent tools (they take `FileRef`/`String`, so already eligible per
      §6.1.1); add an end-to-end coding-loop test (edit → exec build →
      react to `exit_code`, A26).
- [ ] 7.6 `examples/` coding workflow demonstrating edit + build/test via an
      agent, plus a non-agent scripted variant.
- [ ] 6.g (Optional, carried over) serialise agent machine state to skip the
      replay re-walk on resume (§8.2.1) — performance only.

## Backlog — M8+: Deferred, per spec §13

- [ ] 8.1 Control flow: `if`, `foreach`, `par` (shares the M6 agent loop)
- [ ] 8.2 OS-level `exec` isolation (namespaces/seccomp/cgroups) beyond the
      allowlist + empty-env model (§7.5)
- [ ] 8.3 `builtin/eval-workflow` — parse+check+run a workflow produced
      at runtime (reuses M3 checker)
- [ ] 8.4 Cross-run trace reading built-in tool
- [ ] 8.5 Skill extraction from traces
- [ ] 8.6 `Bytes`-typed file I/O
- [ ] 8.7 `trace.jsonl` rotation
- [ ] 8.8 User-level key store (e.g. `$XDG_CONFIG_HOME/hwfi/.env`) as
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
