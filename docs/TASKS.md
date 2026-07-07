# Tasks

Active work only. Move completed sections to `docs/log/archive/` weekly.

Grouped by milestone. Milestones are ordered; within a milestone, tasks are
roughly ordered but can be reshuffled.

## Now — M2: Parsing and AST

- [ ] 2.1 `Hwfi.Parse.Markdown` on top of `commonmark-hs`: split file into
      frontmatter YAML + body blocks + fenced `step` blocks with source
      positions
- [ ] 2.2 Define core AST modules: `Hwfi.Ast.Type`, `Hwfi.Ast.Expr`,
      `Hwfi.Ast.Step`, `Hwfi.Ast.Workflow`, `Hwfi.Ast.Tool`,
      `Hwfi.Ast.TypeAlias`, `Hwfi.Ast.Project`
- [ ] 2.3 Frontmatter parser (YAML) → `Signature { inputs, outputs, imports }`;
      `TypeExpr` sub-parser per spec §3.4 frontmatter grammar
- [ ] 2.4 Type-alias file parser (spec §2.1): `kind: type-alias`,
      `name`, `definition` → `Hwfi.Ast.TypeAlias`
- [ ] 2.5 Step DSL parser (`megaparsec`) implementing spec §3.4 EBNF:
      statements, binder + optional `@id`, discard `_ <-`, explicit
      `return { ... }`, comments (`--`), source-position tracking
- [ ] 2.6 Expression parser per §3.4: literals, short/long strings with
      `${...}` interpolation, lists, records, refs with field/index
      access, bare qnames, `@self#slug`; distinguish bare-ref vs
      in-string interpolation positions (§3.2.1)
- [ ] 2.6b `TypeExpr` parser supports `QName` alias references (§3.4)
- [ ] 2.7 Markdown-section resolver: slug computation (H2/H3 → slug per
      §3.4) and raw-content extraction for `@self#slug`
- [ ] 2.8 Project loader: walk project directory, build
      `Map QualifiedName Declaration`, reject multi-declaration files;
      classify declarations by kind (workflow/tool/type-alias/prompt)
- [ ] 2.9 Golden tests: fixture projects under `test/fixtures/parse/`

## Next — M3: Type checker

- [ ] 3.1 Type representation (`Hwfi.Type`) including `Context`, `Trace`,
      `TraceEvent`, `Secret<T>`, `WorkflowRef`, `ToolRef`
- [ ] 3.2 Type-alias resolution: expand alias references, detect cyclic
      aliases (spec A10)
- [ ] 3.3 Environment building (inputs + step binds + ambient `ctx`),
      scope rules
- [ ] 3.4 Check step calls against callee signatures; unification for
      records/lists; error format per spec §9.1
- [ ] 3.5 `@self#slug` existence check against parsed markdown
- [ ] 3.6 Import-cycle detection over direct call graph
- [ ] 3.7 Static classification: mark each step **cacheable** or
      **non-cacheable** by scanning arg expressions for volatile `ctx.*`
      references and calls to `builtin/introspect`
- [ ] 3.8 `Secret<T>` flow rules: forbid interpolation of `Secret<_>`
      and `Bytes`, auto-tag `ctx.env.*` fields matching secret name
      patterns
- [ ] 3.9 Interpolation rendering typing (§3.2.1): allow any non-Secret,
      non-Bytes type in an interpolation position; enforce return rule
      (§5.6.5, explicit vs implicit `return`)
- [ ] 3.10 Declaration fingerprinting (`fingerprint(d)` Merkle over the
      acyclic direct call graph, §8.1) — computed in the checker, stored
      on `TypedProject` for the runtime to consume
- [ ] 3.11 Factor checker as `Project -> Either [TypeError] TypedProject`
      (pure, no IO) — required for v1.1 dynamic workflow eval
- [ ] 3.12 `hwfi check` end-to-end, integration tests with
      expected-error fixtures

## Later — M4: Runtime and built-in tools

- [ ] 4.1 Executor: linear step interpreter, binding environment,
      argument resolution
- [ ] 4.2 Ambient `ctx` construction and injection into every step;
      `ctx.env` populated only from whitelisted vars per §7.2
- [ ] 4.3 Workspace abstraction with canonicalised root + traversal guard
- [ ] 4.4 Built-in tools: `read-file`, `write-file`, `list-dir`
- [ ] 4.5 `Hwfi.Runtime.Gateways`: build `Map ProviderName LLMGateway`
      directly from `LLM.Providers.*` constructors + `KeyStore`;
      validate provider–key linkage against effective catalog at startup
      (A12); assemble `ModelConfig` values by joining catalog entries
      with gateways; wire `builtin/llm-generate`, `builtin/llm-chat`
      (message-based `GenRequest`, A16), and `builtin/llm-gen-object` on
      top of `LLM.Generate`; unknown-model error lists available names
      (A11)
- [ ] 4.6 Expression evaluator with `eval`-kind runtime errors for list
      OOB and missing `Json` fields (§8.3.2); interpolation rendering
      per §3.2.1
- [ ] 4.7 `builtin/introspect` returning `{ data: Json }`
- [ ] 4.8 Sub-workflow invocation as a step target
- [ ] 4.9 End-to-end sample project (`examples/summarise/`) exercising
      A3 and A9

## Later — M5: Persistence, tracing, resume

- [ ] 5.1 Run directory layout (`.hwfi/runs/<id>/`), `run.json` schema
- [ ] 5.2 Step-key hashing (§8.1): ctx-projection over stable fields,
      `callee-fingerprint` from 3.10, `WorkflowRef`/`ToolRef` args
      contribute referenced fingerprints; canonical JSON for args
- [ ] 5.3 Step result cache read/write; skip cached cacheable steps on
      resume; always re-execute non-cacheable steps; verify code-edit
      invalidation (A13)
- [ ] 5.4 Append-only `trace.jsonl` writer implementing spec §8.3:
      variant encoders (incl. `Resumed`, `eval` error kind), monotonic
      `seq` continuing across attempts, ISO-8601 `at`, ordering
      invariants; cached steps emit no new events
- [ ] 5.5 `ctx.trace` reconstruction on resume by parsing the full
      persisted `trace.jsonl` (§8.3.5); test caching-independence (A15)
- [ ] 5.6 `Secret<T>` redaction in trace serialisation
- [ ] 5.7 Workspace lock file (`.hwfi/lock`) to prevent concurrent runs
- [ ] 5.8 `hwfi resume` command; crash-injection test satisfying A4 and A7
- [ ] 5.9 `hwfi show` pretty-printer for a trace

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
