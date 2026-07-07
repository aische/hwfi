# Status

Last updated: 2026-07-08

## Current focus

**M8 (control flow: `if`/`foreach`/`par`) is complete.** Workflow and tool
bodies are no longer flat statement lists: they can branch and iterate.
Control-flow constructs are **value-producing** and use the same
`binder <- rhs @id` shape as step calls, so caching, tracing, and resume
(§8.1/§8.2) stay uniform. Next candidate work is the carried-over optional
items (agent state serialisation §8.2.1, OS-level `exec` isolation §7.5,
`Bytes` file I/O) or a general control-flow/CEK unification (still deferred).

## Done recently

- `Hwfi.Ast.Step`: `Statement` extended with `SIf`/`SLoop` (`IfStmt`,
  `LoopStmt`, `LoopKind = LoopSeq | LoopPar (Maybe Int)`); `statementId`,
  `blockStatements` helpers.
- `Hwfi.Parse.{Step,Lexer}`: `if`/`else`, `foreach`, `par(max = N)` with
  brace-delimited blocks; `if`/`else`/`foreach`/`par`/`in` reserved.
- `Hwfi.Check.Decl`: recursive body checking (`checkSeq`/`checkStmt`/`checkIf`/
  `checkLoop`) — `cond : Bool`, mandatory `else` + structurally-equal arms for
  value-binding `if`, `List<T>` iteration binding `v : T`, `List<U>` loop
  result, no-shadowing, and a **flat per-declaration id namespace** (step
  binders, loop vars, construct `@id`s must all be unique).
- `Hwfi.Check.Graph` + `Hwfi.Check`: `directCallees`, fingerprint `encodeStmt`,
  and the `builtin/exec` policy pass all recurse into control-flow blocks.
- `Hwfi.Runtime.Trace`: `IfBranch`/`LoopStart`/`LoopIter`/`LoopEnd` events
  (JSON round-trip + `hwfi show` render); tracer now holds an `MVar` mutex so
  concurrent `par` iterations serialise `emit` (consistent `seq` + file order).
- `Hwfi.Runtime.Executor`: `execIf`/`execLoop`; sequential `foreach` and
  bounded, order-preserving `par` (`pooledForConcurrentlyN`, default 4, aborts
  on lowest-index failure). A **scope prefix** (`check#2/c`, `mode?then/s`) is
  threaded into `stepKeyFor` so dynamically-distinct occurrences of a static
  step get distinct cache keys — per-iteration resume correctness.
- `examples/control-flow`: scripted `par` syntax-check + `foreach` manifest +
  `if`/`else` summary; `check`/`run` verified.
- 207 tests (was 188): parser cases (StepSpec), trace round-trip (TraceSpec),
  and a new `Hwfi.Runtime.ControlFlowSpec` (foreach/par/if execution, ordered
  results, `par` concurrency, resume durability, and checker rejections).

## Blockers

- None.

## Notes / decisions

- Control flow is value-producing: a block's value is its last statement's
  value (empty block → empty record). This keeps the linear binding model
  uniform and makes conditional/loop results first-class.
- Step ids are globally unique **within a declaration**, including across `if`
  branches, so `then`/`else` arms cannot reuse a binder name (checked, A-dup).
  **Open decision (revisit before v1 freeze):** keep this flat namespace or move
  to block-local scoping — see spec §4.2 and TASKS → DEC-1.
- `par` result ordering is by input index (not completion); the first error is
  the lowest-index one. Iterations write to distinct cache keys/paths, so
  concurrent cache writes are safe; only the tracer's `emit` is serialised.
- Scope is threaded into sub-workflow calls too (call-site-prefixed keys):
  favours per-iteration resume correctness over cross-call cache sharing.
- Durable-workspace invariant (§8.2) holds through loops/branches: a completed
  iteration's step is served from cache on resume and its side effect is not
  re-applied (verified in ControlFlowSpec).

## Next up

See [TASKS.md](TASKS.md) → carried-over optional items (agent state
serialisation §8.2.1, OS-level `exec` isolation §7.5, `Bytes`-typed file I/O)
and the M9+ backlog.
