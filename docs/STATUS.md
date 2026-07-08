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

- **DEC-1 closed:** block-local identifier scoping (spec §4.2). `@id`s are
  unique per block; sibling branches/loops may reuse names. Checker updated;
  `examples/control-flow` demonstrates mirrored `@notify` in `if` arms.
- `Hwfi.Ast.Step`: `Statement` extended with `SIf`/`SLoop` (`IfStmt`,
  `LoopStmt`, `LoopKind = LoopSeq | LoopPar (Maybe Int)`); `statementId`,
  `blockStatements` helpers.
- `Hwfi.Parse.{Step,Lexer}`: `if`/`else`, `foreach`, `par(max = N)` with
  brace-delimited blocks; `if`/`else`/`foreach`/`par`/`in` reserved.
- `Hwfi.Check.Decl`: recursive body checking — branch typing, mandatory
  `else`, `List<T>` iteration, `List<U>` loop result, no-shadowing,
  per-block `@id` uniqueness.
- `Hwfi.Check.Graph` + `Hwfi.Check`: callee/fingerprint/exec-policy recursion
  through control-flow blocks.
- `Hwfi.Runtime.Executor`: scope prefix in step keys for per-iteration resume.
- `examples/control-flow`: `par` + `foreach` + mirrored `if`/`else`.
- 210 tests (was 207): block-local scoping acceptance/rejection cases.

## Blockers

- None.

## Notes / decisions

- **Block-local scoping (§4.2):** inner binds don't escape; no shadowing outward;
  `@id` unique within a block; sibling branches may reuse binders and `@id`s.
- Control flow is value-producing: a block's value is its last statement's
  value (empty block → empty record).
- `par` result ordering is by input index; aborts on lowest-index failure.
- Scope prefix threaded into sub-workflow calls (per-iteration resume over
  cross-call cache sharing).
- Durable-workspace invariant (§8.2) holds through loops/branches.

## Next up

See [TASKS.md](TASKS.md) → carried-over optional items and M9+ backlog.
