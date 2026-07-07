# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

Grouped by milestone. Milestones are ordered; within a milestone, tasks are
roughly ordered but can be reshuffled.

## Now — M1: Project skeleton

- [ ] 1.1 Initialize cabal project (`wfe.cabal`, `cabal.project`) with GHC2021,
      library + executable + test-suite stanzas
- [ ] 1.2 Wire `../llm-simple` as a local `packages:` entry in `cabal.project`;
      confirm a trivial `import LLM.Simple.Generate` compiles
- [ ] 1.3 Add `hspec` (or `tasty` — pick one, document choice) and a smoke test
- [ ] 1.4 Add `optparse-applicative` CLI stub with `check`, `run`, `resume`,
      `show` subcommands that print "not implemented" and exit 0/1 appropriately

## Next — M2: Parsing and AST

- [ ] 2.1 Decide markdown parser (`commonmark-hs` recommended); record choice
      in `docs/log/`
- [ ] 2.2 Define core AST modules: `Wfe.Ast.Type`, `Wfe.Ast.Expr`,
      `Wfe.Ast.Step`, `Wfe.Ast.Workflow`, `Wfe.Ast.Tool`, `Wfe.Ast.Project`
- [ ] 2.3 Frontmatter parser (YAML) → `Signature { inputs, outputs, imports }`
- [ ] 2.4 Step-block parser: extract fenced ```step blocks, parse JSON payload,
      validate shape
- [ ] 2.5 Expression parser for `${...}` accessors (no operators in v1)
- [ ] 2.6 Project loader: walk project directory, build
      `Map QualifiedName Declaration`
- [ ] 2.7 Golden tests: fixture projects under `test/fixtures/parse/`

## Next — M3: Type checker

- [ ] 3.1 Type representation (`Wfe.Type`) with unification for `Record`s and
      `List`s
- [ ] 3.2 Environment building (inputs + step binds), scope rules
- [ ] 3.3 Check step calls against callee signatures; report file+step id on
      mismatch
- [ ] 3.4 Import-cycle detection over direct call graph
- [ ] 3.5 `wfe check` end-to-end, integration tests with expected-error fixtures

## Later — M4: Runtime and built-in tools

- [ ] 4.1 Executor: linear step interpreter, binding environment, argument
      resolution
- [ ] 4.2 Workspace abstraction with canonicalised root + traversal guard
- [ ] 4.3 Built-in tools: `read-file`, `write-file`, `list-dir`
- [ ] 4.4 Integrate `llm-simple`: `builtin/llm-generate`,
      `builtin/llm-gen-object`; model catalog loading via `Load` module
- [ ] 4.5 Sub-workflow invocation as a step target
- [ ] 4.6 End-to-end sample project (`examples/summarise/`) exercising A3

## Later — M5: Persistence, tracing, resume

- [ ] 5.1 Run directory layout (`.wfe/runs/<id>/`), `run.json` schema
- [ ] 5.2 Step-key hashing (stable across runs; canonical JSON for args)
- [ ] 5.3 Step result cache read/write; skip cached steps on resume
- [ ] 5.4 Append-only `trace.jsonl` event stream with defined event types
- [ ] 5.5 Workspace lock file to prevent concurrent runs
- [ ] 5.6 `wfe resume` command; crash-injection test satisfying A4
- [ ] 5.7 `wfe show` pretty-printer for a trace

## Backlog — M6+: Deferred, per spec §13

- [ ] 6.1 Control flow: `if`, `foreach`, `par`
- [ ] 6.2 Shell/exec built-in tool with sandbox policy
- [ ] 6.3 `WorkflowRef` values constructable from `Json` (dynamic workflows)
- [ ] 6.4 Trace-introspection built-in tool
- [ ] 6.5 Skill extraction from traces

## Cross-cutting

- [ ] X.1 Decide command name (`wfe` placeholder) and lock it in
- [ ] X.2 Resolve every **[open]** in `docs/spec.md` before starting the
      corresponding milestone; log each decision in `docs/log/`

## Done

_Move items here temporarily, then archive to `docs/log/archive/tasks-YYYY-MM.md`._
