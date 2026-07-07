# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

Grouped by milestone. Milestones are ordered; within a milestone, tasks are
roughly ordered but can be reshuffled.

## Now — M1: Project skeleton

- [ ] 1.1 Initialize cabal project (`wfe.cabal`, `cabal.project`) with GHC2021,
      library + executable + test-suite stanzas
- [ ] 1.2 Wire `../llm-simple` as a local `packages:` entry in
      `cabal.project`; confirm a trivial `import LLM.Simple.Generate`
      compiles
- [ ] 1.3 Add `hspec` (or `tasty` — pick one, document choice) and a smoke
      test
- [ ] 1.4 Add `optparse-applicative` CLI stub with `check`, `run`, `resume`,
      `show` subcommands that print "not implemented" and exit
      appropriately
- [ ] 1.5 `project.json` schema module + parser (fields: `name`, `version`,
      `entrypoint`, optional `env` whitelist)

## Next — M2: Parsing and AST

- [ ] 2.1 Decide markdown parser (recommend `commonmark-hs`); record choice
      in `docs/log/`
- [ ] 2.2 Define core AST modules: `Wfe.Ast.Type`, `Wfe.Ast.Expr`,
      `Wfe.Ast.Step`, `Wfe.Ast.Workflow`, `Wfe.Ast.Tool`, `Wfe.Ast.Project`
- [ ] 2.3 Frontmatter parser (YAML) → `Signature { inputs, outputs, imports }`
- [ ] 2.4 Step DSL parser (`megaparsec`): statements `<bind> <- <qname>(args)`,
      optional `@id`, discard `_ <-`, explicit `return { ... }` blocks
- [ ] 2.5 Expression parser: literals, interpolated strings, triple-quoted
      strings, lists, records, `${...}` refs, bare qnames, `@self#slug`
- [ ] 2.6 Markdown-section resolver: map H2/H3 slugs to raw content for
      `@self#slug`
- [ ] 2.7 Project loader: walk project directory, build
      `Map QualifiedName Declaration`, reject multi-declaration files
- [ ] 2.8 Golden tests: fixture projects under `test/fixtures/parse/`

## Next — M3: Type checker

- [ ] 3.1 Type representation (`Wfe.Type`) including `Context`, `Trace`,
      `TraceEvent`, `Secret<T>`, `WorkflowRef`, `ToolRef`
- [ ] 3.2 Environment building (inputs + step binds + ambient `ctx`), scope
      rules
- [ ] 3.3 Check step calls against callee signatures; unification for
      records/lists; report file+step id on mismatch
- [ ] 3.4 `@self#slug` existence check against parsed markdown
- [ ] 3.5 Import-cycle detection over direct call graph
- [ ] 3.6 Static classification: mark each step **cacheable** or
      **non-cacheable** by scanning arg expressions for volatile `ctx.*`
      references and calls to `builtin/introspect`
- [ ] 3.7 `Secret<T>` flow rules: forbid interpolation into plain `String`,
      auto-tag `ctx.env.*` fields matching secret name patterns
- [ ] 3.8 Factor checker as `Project -> Either [TypeError] TypedProject`
      (pure, no IO) — required for v1.1 dynamic workflow eval
- [ ] 3.9 `wfe check` end-to-end, integration tests with expected-error
      fixtures

## Later — M4: Runtime and built-in tools

- [ ] 4.1 Executor: linear step interpreter, binding environment,
      argument resolution
- [ ] 4.2 Ambient `ctx` construction and injection into every step
- [ ] 4.3 Workspace abstraction with canonicalised root + traversal guard
- [ ] 4.4 Built-in tools: `read-file`, `write-file`, `list-dir`
- [ ] 4.5 Integrate `llm-simple`: `builtin/llm-generate`,
      `builtin/llm-gen-object`; model catalog loading via `Load` module
- [ ] 4.6 `builtin/introspect` returning `{ data: Json }`
- [ ] 4.7 Sub-workflow invocation as a step target
- [ ] 4.8 End-to-end sample project (`examples/summarise/`) exercising A3
      and A9

## Later — M5: Persistence, tracing, resume

- [ ] 5.1 Run directory layout (`.wfe/runs/<id>/`), `run.json` schema
- [ ] 5.2 Step-key hashing including ctx-projection over stable fields
      only; canonical JSON for args
- [ ] 5.3 Step result cache read/write; skip cached cacheable steps on
      resume; always re-execute non-cacheable steps
- [ ] 5.4 Append-only `trace.jsonl` with the event schema in spec §8.3
- [ ] 5.5 `Secret<T>` redaction in trace serialisation
- [ ] 5.6 Workspace lock file to prevent concurrent runs
- [ ] 5.7 `wfe resume` command; crash-injection test satisfying A4 and A7
- [ ] 5.8 `wfe show` pretty-printer for a trace

## Backlog — M6+: Deferred, per spec §13

- [ ] 6.1 Control flow: `if`, `foreach`, `par`
- [ ] 6.2 Shell/exec built-in tool with sandbox policy
- [ ] 6.3 `builtin/eval-workflow` — parse+check+run a workflow produced at
      runtime (reuses M3 checker)
- [ ] 6.4 Cross-run trace reading built-in tool
- [ ] 6.5 Skill extraction from traces
- [ ] 6.6 `Bytes`-typed file I/O
- [ ] 6.7 `trace.jsonl` rotation

## Cross-cutting

- [ ] X.1 Decide command name (`wfe` placeholder) and lock it in
- [ ] X.2 Resolve every **[open]** in `docs/spec.md` before starting the
      corresponding milestone; log each decision in `docs/log/`

## Done

_Move items here temporarily, then archive to
`docs/log/archive/tasks-YYYY-MM.md`._
