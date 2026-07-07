# Specification

Concrete requirements derived from [idea.md](idea.md). This spec pins v1 scope.
Anything marked **[open]** is an unresolved design decision.

## 1. Product summary

A command-line workflow engine, written in Haskell (GHC2021), that:

1. Loads a workflow project consisting of markdown files and a few JSON files.
2. Parses and **type-checks** the entire project before executing anything.
3. Executes the workflow, with access to a designated workspace folder
   (read/create/modify files) and to LLMs via the local `llm-simple` library.
4. Persists execution state and a full trace so runs are **resumable** after
   crash or abort.
5. Exposes the run's environment (workspace, prior trace, inputs) to every
   step via a typed ambient `Context`, so agent steps can inspect what
   happened before them.
6. Is designed so that, in a later stage, agent steps can synthesize new
   workflows at runtime, type-check them against the same checker used at
   load time, and read prior traces to learn or extract skills.

Non-goals for v1: GUI, remote/distributed execution, multi-tenant isolation,
a package registry for workflows.

## 2. Project layout (input)

A workflow project is a directory with:

```
project.json                # project manifest (name, entrypoint, env whitelist, version)
workflows/
  main.md                   # a workflow definition
  <name>.md                 # more workflows, addressable by relative path
tools/
  <name>.md                 # tool definitions (prompt-backed or built-in ref)
types/                      # [open] optional shared type declarations
  <name>.json
```

- Every `.md` file is a single top-level declaration (one workflow, one tool,
  or one prompt fragment). Multiple declarations per file are rejected.
- File path (relative to project root, without extension) is the declaration's
  fully-qualified name. Renaming a file changes the qualified name; callers
  must be updated. This is the intended semantics (analogous to renaming a
  module in a programming language).

`project.json` shape (v1):

```json
{
  "name": "example",
  "version": "0.1.0",
  "entrypoint": "workflows/main",
  "env": ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"]
}
```

`env` is optional; when present, it whitelists process environment variables
that will be readable via `ctx.env` at runtime. Anything not listed is not
visible to the workflow.

## 3. Markdown workflow syntax (v1)

A workflow markdown file has:

1. **YAML frontmatter** with typed `inputs`, `outputs`, and optional `imports`.
2. A **body** consisting of prose (documentation, ignored by executor) and
   **step blocks**: fenced code blocks with info string `step`.

### 3.1 Step DSL

Inside a `step` block, one statement per line:

```
<bind> <- <qname>(<args>)             -- step id defaults to bind name
<bind> <- <qname>(<args>) @<id>       -- explicit step id
_      <- <qname>(<args>) @<id>       -- discard result; id required
```

Rules:

- Bind names must be unique within a workflow (no shadowing in v1).
- `<qname>` is the fully-qualified name of a tool or sub-workflow, or a
  first-class ref parameter in scope of type `ToolRef`/`WorkflowRef`.
- `<args>` is a comma-separated list `key = expr, key = expr`. Whitespace
  and newlines inside the parentheses are allowed.
- Multiple statements per block are allowed; blocks may be interleaved with
  prose in any order. Execution order = source order.
- A workflow may declare an explicit `return` block instead of relying on
  the last step's bind:

  ```
  ```step
  return { summary = ${summary}, count = ${n} }
  ```
  ```

### 3.2 Expression sub-language

- Literals: `"..."`, numbers, `true`, `false`, `null`.
- String interpolation: `"hello ${name}"` inside double-quoted strings.
- Multi-line string: `"""..."""` (triple-quoted, interpolation supported).
- List: `[e, e, ...]`.
- Record: `{ k = e, k = e }`.
- Reference: `${path.to.value}`, where the path resolves against the current
  binding environment (see §5.3).
- Bare qname: `builtin/llm-generate` — permitted only where the target
  parameter is `ToolRef` or `WorkflowRef`.
- Markdown-section reference: `@self#<heading-slug>` — evaluates to the
  raw markdown content under the H2/H3 with that slug in the *current* file.
  Typed as `String`. Intended for keeping long prompts in prose form.

No arithmetic, no conditionals, no lambdas in v1.

### 3.3 Example

````markdown
---
name: summarise-file
inputs:
  path: FileRef
outputs:
  summary: String
imports:
  - builtin/read-file
  - builtin/llm-generate
---

## system

You are a concise summariser. Return one paragraph, no preamble.

## flow

Read the file and summarise it.

```step
contents <- builtin/read-file(path = ${inputs.path})
summary  <- builtin/llm-generate(
  system = @self#system,
  prompt = "Summarise the following:\n\n${contents.text}",
  model  = "gpt-5"
)
```
````

## 4. Control flow (v1)

- Sequential steps only.
- **[deferred v1.1]** `if`, `foreach`, `par`.
- Errors abort the workflow; the failing step is recorded and the run is
  resumable from that step.

## 5. Type system (v1)

### 5.1 Base types

- `String`, `Int`, `Double`, `Bool`
- `Json` (opaque structured value)
- `Bytes` (opaque byte blob)
- `FileRef` (path inside the workspace; existence not required at type-check
  time, only when read)
- `List<T>`, `Record<{ field: T, ... }>`
- `WorkflowRef<In, Out>`, `ToolRef<In, Out>` — first-class references,
  needed for dynamic workflow synthesis in stage 2

### 5.2 Built-in context types

The following types are defined by the engine and always in scope:

```
Context = Record {
  workspace : FileRef,
  run       : Record { id: String, started_at: String, entrypoint: String },
  self      : Record { qname: String, step_id: String },
  inputs    : Json,             -- root workflow inputs
  trace     : Trace,            -- structured, current run, up to and
                                --   including events preceding this step
  env       : Record { ... }    -- shape derived from project.json `env`
}

Trace       = List<TraceEvent>
TraceEvent  = one of the tagged variants listed in §8.3

Secret<T>   = wrapper around a value of type T that never appears in the
              trace as-is; serialised as "<secret:name>" (see §5.5)
```

### 5.3 Binding environment

Inside a step's argument expressions, the following names are in scope:

- `inputs` — the enclosing workflow's declared inputs.
- Any prior step's `bind` name in the current workflow.
- `ctx` — the ambient `Context` value (see §5.4).

### 5.4 Ambient context

Every workflow and tool implicitly receives `ctx : Context`. It is not
declared as an input and not passed explicitly at call sites. Access is
via `${ctx.<field>}` expressions.

Consequences for step-key hashing are in §8.2.

### 5.5 Secrets

`Secret<String>` is used for API keys, tokens, and any user-marked
sensitive value. Rules:

- Values loaded from `ctx.env` for keys whose name matches
  `*_KEY|*_TOKEN|*_SECRET|*_PASSWORD` (case-insensitive) are automatically
  typed as `Secret<String>`.
- A `Secret<T>` cannot be interpolated into a plain `String` expression;
  it must be passed to a tool whose parameter is declared `Secret<T>`.
- Trace events redact any field typed `Secret<_>` as `"<secret:$name>"`
  before persistence.

### 5.6 Type-checking rules

1. Every step's `<qname>` must resolve to a declared workflow, tool, or a
   `WorkflowRef`/`ToolRef` value in scope.
2. `args` structure must match the callee's declared inputs.
3. Every `${...}` reference must resolve in the binding environment; its
   type must match the target position.
4. `@self#<heading>` is checked to exist in the current file; type `String`.
5. The final `return` block (or the last step's bind, if no explicit
   return) must produce values matching declared `outputs`.
6. Cycles in the direct call graph across workflows are detected and
   rejected. Indirect references via `WorkflowRef` values are allowed.
7. The checker is a pure function `Project -> Either [TypeError] TypedProject`
   so the same checker runs both at load time (`wfe check`) and at runtime
   over dynamically synthesized workflows (see §13).

## 6. Built-in tools (v1)

Provided by the engine, addressed as `builtin/<name>`:

- `builtin/read-file` : `{ path: FileRef } -> { text: String }`
- `builtin/write-file` : `{ path: FileRef, text: String } -> {}`
- `builtin/list-dir` : `{ path: FileRef } -> { entries: List<String> }`
- `builtin/llm-generate` : `{ system: String, prompt: String, model?: String }
  -> { text: String }` (backed by `llm-simple`
  `Generate.generateTextWithFallbacks`)
- `builtin/llm-gen-object` : `{ system: String, prompt: String, schema: Json,
  model?: String } -> { value: Json }` (backed by `genObject` /
  `genObjectUntyped`)
- `builtin/introspect` : `{} -> { data: Json }` — escape hatch returning a
  JSON dump of everything the runtime knows about the current run
  (including full trace, all bindings, workspace path, project metadata).
  Marks the calling step non-cacheable (§8.2).

**[deferred v1.1]** shell/exec tool.

## 7. Workspace and sandboxing

- Engine receives `--workspace <dir>` on the CLI.
- All `FileRef` values are resolved relative to the workspace root.
- Path traversal outside the workspace is rejected at runtime; the
  workspace root is canonicalised once at start.
- The workspace is the **only** filesystem area the workflow may write to.
- The project directory (workflows/tools) is read-only during execution.
- Network access is available only via `llm-simple` calls invoked by
  `builtin/llm-*`; no arbitrary HTTP tool in v1.
- `ctx.env` contains only variables whitelisted in `project.json`.

## 8. Persistence and resumability

Every run has a `run id` (ULID). Run artifacts are stored under
`<workspace>/.wfe/runs/<run-id>/` (name **[open]**: `.wfe` placeholder):

```
run.json          # run metadata: project hash, entrypoint, inputs, status
steps/
  <step-key>.json # one file per completed cacheable step
trace.jsonl       # append-only event log
```

### 8.1 Step-key hashing

`step-key = hash(qname, step-id, resolved-args, ctx-projection)` where
`ctx-projection` includes only those `ctx.*` fields the step actually
references, restricted to *stable* fields:

- Stable: `ctx.workspace`, `ctx.run.id`, `ctx.self.qname`, `ctx.self.step_id`,
  `ctx.inputs.*`, `ctx.env.*`.
- Volatile: `ctx.trace`, `ctx.run.started_at`, and anything reachable via
  `builtin/introspect`.

A step that references any volatile `ctx` field, or calls
`builtin/introspect`, is **non-cacheable** and is always re-executed on
resume. This is statically decidable at type-check time and recorded on
the AST node.

### 8.2 Resume semantics

- Cacheable steps: skipped on resume if their `step-key` has a persisted
  result.
- Non-cacheable steps: always re-executed. Rationale: their whole purpose
  is to observe the current trace or environment, so replaying with cached
  output would defeat the point.
- A step is atomic: partial LLM output is not resumed mid-call.
- A run is resumable if `run.json.status ∈ {running, crashed, aborted}`.

### 8.3 Trace event schema

`trace.jsonl` is append-only, one JSON object per line, one of:

- `{ tag: "run-start",   run_id, entrypoint, inputs, at }`
- `{ tag: "step-start",  qname, step_id, args, at }`
- `{ tag: "step-end",    qname, step_id, result, cached: bool, at }`
- `{ tag: "llm-call",    model, system, prompt, response, tokens, at }`
- `{ tag: "file-io",     op, path, bytes, at }`
- `{ tag: "error",       qname, step_id, message, at }`
- `{ tag: "run-end",     run_id, status, at }`

`Secret<_>`-typed values in `args`, `result`, `system`, `prompt`,
`response` are redacted per §5.5.

## 9. CLI

Minimal v1 surface (command name `wfe` **[open]**):

```
wfe check   <project-dir>
wfe run     <project-dir> --workspace <dir> [--input k=v]... [--entry <name>]
wfe resume  <workspace-dir> <run-id>
wfe show    <workspace-dir> <run-id>          # pretty-print trace
```

`wfe check` performs parse + type-check only, exits non-zero on any error.

## 10. Dependencies and tooling

- GHC2021.
- Cabal project. `llm-simple` referenced as a local `packages:` entry
  pointing at `../llm-simple` via `cabal.project`.
- Libraries expected: `aeson`, `text`, `bytestring`, `containers`,
  `filepath`, `directory`, `unliftio` or `async`, `megaparsec` (for the
  step DSL), a markdown parser (**[open]**: `commonmark-hs` recommended),
  `optparse-applicative`, `ulid` or `uuid`, `cryptonite` or `hashable` for
  step-key hashing.

## 11. Acceptance criteria (v1)

A1. `wfe check` on a well-formed project exits 0 and prints nothing on
    stderr.
A2. `wfe check` on a project with an undeclared reference, type mismatch,
    or import cycle exits non-zero with a message pointing at file and
    step id.
A3. `wfe run` on a two-step sample workflow
    (`read-file` → `llm-generate`) produces the expected output file in
    the workspace and a populated `.wfe/runs/<id>/` directory.
A4. Killing the process mid-run and invoking `wfe resume` completes the
    run without re-executing already-persisted cacheable steps (verified
    by a step that writes a marker file and would double-write on
    re-execution).
A5. Attempting to write to a path outside the workspace fails with a
    clear error and is recorded in the trace.
A6. A workflow can call another workflow as a step; type-checking
    enforces the callee's signature.
A7. A step whose args reference `${ctx.trace}` is re-executed on resume;
    a step that does not is skipped when cached.
A8. `Secret<String>` values loaded from `ctx.env` never appear in
    `trace.jsonl` in cleartext; they render as `<secret:$name>`.
A9. `@self#heading` in a step arg resolves to the current file's markdown
    content under that heading; mismatched slug fails at `wfe check`.

## 12. Edge cases and known tricky bits

- Non-UTF-8 files in the workspace: v1 treats `read-file` as text and
  errors on invalid UTF-8. Byte-oriented read deferred to v1.1 via
  `Bytes` type (already reserved in §5.1).
- Very large LLM outputs: step results are written to disk, not held in
  RAM beyond the current step's needs.
- Renaming a workflow file mid-project changes qualified names and
  invalidates cached step keys — acceptable, documented.
- Concurrent runs sharing a workspace: v1 requires an exclusive lock file
  under `.wfe/`; second `run` fails fast.
- Circular tool imports: rejected at type-check.
- Trace growth over long runs: `trace.jsonl` is append-only text; v1
  imposes no size cap. Rotation deferred to v1.1.

## 13. Explicitly deferred to v1.1+

- Control flow (`if`, `foreach`, `par`).
- Shell/exec tool with sandbox policy.
- Dynamic workflow synthesis by agents. The type checker is already
  factored as a pure function (§5.6) so it can be re-invoked at runtime
  on a freshly-parsed workflow; what remains for v1.1 is a built-in tool
  along the lines of `builtin/eval-workflow(source: String, inputs: Json)
  -> { outputs: Json }` that parses, type-checks, and runs a workflow
  produced by another step.
- Cross-run trace reading (reading prior runs' `trace.jsonl`).
- Skill extraction from traces.
- `Bytes`-typed file I/O.
- `trace.jsonl` rotation.
