# Specification

Concrete requirements derived from [idea.md](idea.md). This spec pins v1 scope.
Anything marked **[deferred v1.1]** is intentionally out of scope for v1.

Known gaps between this spec and the current engine are listed in §14 (with
matching backlog items in [TASKS.md](TASKS.md) → H1).

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
project.json                # project manifest
.env                        # optional: provider API keys (see §7.2)
model-catalog.json          # required: model + provider config (see §7.3)
workflows/
  main.md                   # a workflow definition
  <name>.md                 # more workflows, addressable by relative path
tools/
  <name>.md                 # tool definitions (prompt-backed or built-in ref)
types/
  <name>.md                 # shared type declarations (see §2.1)
```

- Every `.md` file is a single top-level declaration (one workflow, one tool,
  one prompt fragment, or one type alias). Multiple declarations per file
  are rejected.
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
  "env": [],
  "exec": {
    "allow": ["git", "cabal", "ghc"],
    "env": ["PATH", "HOME"],
    "timeout_ms": 120000,
    "max_output_bytes": 1048576
  }
}
```

`env` is optional (defaults to `[]`); when present, it whitelists process
environment variables that will be readable via `ctx.env` at runtime.
Anything not listed is not visible to the workflow. Provider API keys
(`OPENAI_API_KEY`, `CLAUDE_API_KEY`, `GEMINI_API_KEY`, `DEEPSEEK_API_KEY`)
do **not** need to be in `env`: they are consumed by `hwfi`'s own
gateway loader and never flow through `ctx.env` — see §7.2.

`exec` is optional and **absent by default, in which case `builtin/exec`
is disabled** (any call to it fails at `hwfi check`). It is the opt-in
policy for command execution (§6.3, §7.5):

- `allow` — the whitelist of program **basenames** that `builtin/exec`
  may run (e.g. `"git"`, not `"/usr/bin/git"`). An empty or absent list
  disables `exec` entirely. There is no wildcard in v1.
- `env` — process environment variable names passed through to spawned
  commands (defaults to `[]`; the child otherwise gets an empty
  environment). Provider API keys are never passed unless explicitly
  listed here, which is discouraged.
- `timeout_ms` — default wall-clock timeout applied to each `exec` call
  when the call does not specify its own (defaults to `120000`).
- `max_output_bytes` — cap on captured `stdout`/`stderr` per stream;
  output beyond the cap is truncated and flagged (defaults to `1048576`).

### 2.1 Shared type declarations

Files under `types/` declare reusable type aliases. Each is a markdown
file with a specific frontmatter shape and no body-level step blocks:

```markdown
---
kind: type-alias
name: types/message
definition: Record<{ role: String, content: String }>
---

Optional prose documentation.
```

- `kind` must equal `type-alias`.
- `name` must equal the file's qualified name (path minus extension).
- `definition` is a `TypeExpr` (see §3.4 grammar), which may reference
  other type aliases by qname.
- Aliases are resolved during type-checking; cycles are rejected.
- Aliases may be referenced from any workflow or tool signature or from
  another alias by writing the qname where a `TypeExpr` is expected
  (e.g. `inputs: { m: types/message }`).

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

#### 3.2.1 References vs. string interpolation

There are two syntactically distinct positions for a `${...}` reference,
with different typing:

- **Bare reference** — a `${ref}` that *is* the whole expression (e.g.
  `text = ${contents.text}`). Its type is exactly the referenced value's
  type; no conversion happens. This is how structured values (records,
  lists, `Json`) are passed between steps.
- **Interpolated reference** — a `${ref}` appearing *inside* a string
  literal (e.g. `"Summarise:\n${contents.text}"`). The referenced value
  is **rendered to text** and spliced into the surrounding string. The
  whole literal has type `String`.

Rendering rules for interpolation (total and statically decidable):

| Referenced type      | Rendered as                                    |
|----------------------|------------------------------------------------|
| `String`             | verbatim                                        |
| `Int`, `Double`      | canonical decimal literal                       |
| `Bool`               | `true` / `false`                                |
| `null` (literal)     | `null`                                          |
| `FileRef`            | its workspace-relative path                     |
| `Json`, `List<_>`, `Record<{…}>`, `Trace`, `TraceEvent`, `Context` | compact canonical JSON (sorted keys) |
| `Bytes`              | **static error** — no implicit text encoding    |
| `Secret<_>`          | **static error** — see §5.5                     |

Because the referenced type is always known at check time, interpolation
never produces a runtime type error; only `Bytes` and `Secret<_>` in an
interpolation position are rejected, and that rejection happens at
`hwfi check`.

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

### 3.4 Grammar (EBNF)

Notation: `X*` zero-or-more, `X+` one-or-more, `X?` optional, `|`
alternation, `"..."` literal terminal, `<lower>` non-terminal, `(...)`
grouping. `\n` denotes a line terminator.

```
(* --- Step block (contents of a ```step fenced code block) --- *)

StepBlock       = Sep? Statement (Sep+ Statement)* Sep? ;
Statement       = ReturnStmt | StepStmt ;
StepStmt        = Binder "<-" QName "(" ArgList? ")" StepId? ;
Binder          = Ident | "_" ;
StepId          = "@" Ident ;
ReturnStmt      = "return" Record ;

ArgList         = Arg ("," Arg)* ","? ;
Arg             = Ident "=" Expr ;

(* --- Names --- *)

QName           = Segment ("/" Segment)+     (* declared tool/workflow *)
                | Ident ;                    (* bare, only where a
                                                ToolRef/WorkflowRef value
                                                is in scope *)
Segment         = Ident ;
Ident           = Letter (Letter | Digit | "-" | "_")* ;

(* --- Expressions --- *)

Expr            = Literal
                | Ref
                | List
                | Record
                | SelfRef
                | QName ;                    (* bare ref *)

Literal         = StringLit | NumberLit | BoolLit | NullLit ;
BoolLit         = "true" | "false" ;
NullLit         = "null" ;
NumberLit       = "-"? Digit+ ("." Digit+)? Exp? ;
Exp             = ("e" | "E") ("+" | "-")? Digit+ ;

StringLit       = ShortString | LongString ;
ShortString     = "\"" (ShortChar | Interp)* "\"" ;
LongString      = "\"\"\"" (LongChar | Interp)* "\"\"\"" ;
ShortChar       = <any Unicode char except '"', '\', '\n'> | Escape ;
LongChar        = <any Unicode char except '"""'>         | Escape ;
Escape          = "\\" ( "\"" | "\\" | "n" | "r" | "t"
                       | "u" HexDigit HexDigit HexDigit HexDigit ) ;
Interp          = "${" RefPath "}" ;

Ref             = "${" RefPath "}" ;
RefPath         = Ident (FieldAccess | IndexAccess)* ;
FieldAccess     = "." Ident ;
IndexAccess     = "[" NumberLit "]" ;

List            = "[" (Expr ("," Expr)* ","?)? "]" ;
Record          = "{" (Field ("," Field)* ","?)? "}" ;
Field           = Ident "=" Expr ;

SelfRef         = "@self#" Slug ;
Slug            = (Letter | Digit | "-" | "_")+ ;

(* --- Lexical --- *)

Letter          = "A".."Z" | "a".."z" ;
Digit           = "0".."9" ;
HexDigit        = Digit | "a".."f" | "A".."F" ;

Sep             = (Comment? "\n")+ ;          (* one or more line breaks *)
Comment         = "--" <any char except "\n">* ;
Whitespace      = (" " | "\t")+ ;             (* insignificant between
                                                 tokens, ignored by parser *)
```

Additional lexical rules:

- Reserved keywords (cannot be `Ident`): `return`, `true`, `false`,
  `null`, `_`.
- Horizontal whitespace and comments are permitted between any two
  adjacent tokens without changing meaning.
- Inside `(...)`, `[...]`, `{...}`, `"..."`, and `"""..."""`, `\n` is
  permitted freely and does **not** terminate a `Statement`.
- Outside those brackets, `\n` (or a comment ending in `\n`) is the
  `Statement` terminator. A trailing separator after the last statement
  is allowed.
- Slug matching for `SelfRef` is case-insensitive; slugs are computed
  from H2/H3 heading text by lowercasing, replacing runs of non-word
  characters with `-`, and trimming leading/trailing `-`.
- Two statements binding the same `Ident` are a static error (no
  shadowing).

Frontmatter grammar (YAML, no separate EBNF; validated against a fixed
schema):

```
Frontmatter :=
  name       : String                        (* must equal the file's
                                                qualified name *)
  inputs     : Map<Ident, TypeExpr>          (* optional, defaults to {} *)
  outputs    : Map<Ident, TypeExpr>          (* optional, defaults to {} *)
  imports    : List<QName>                   (* optional, defaults to [] *)

TypeExpr    := "String" | "Int" | "Double" | "Bool"
             | "Json" | "Bytes" | "FileRef"
             | "List<" TypeExpr ">"
             | "Record<{" (Ident ":" TypeExpr) ("," Ident ":" TypeExpr)* "}>"
             | "WorkflowRef<" TypeExpr "," TypeExpr ">"
             | "ToolRef<"     TypeExpr "," TypeExpr ">"
             | "Secret<"      TypeExpr ">"
             | "Context" | "Trace" | "TraceEvent"
             | QName ;                    (* reference to a type alias
                                             declared under types/, §2.1 *)
```

`TypeExpr` is a small string language embedded in YAML string values.
It is parsed by the same lexer/parser as the step DSL, restricted to
type productions. A `QName` in type position must resolve to a
`type-alias` declaration (§2.1); resolution and cycle detection happen
during type-checking. Note the deliberate punctuation split: **types**
use `:` (as in `Record<{ name: String }>` and YAML frontmatter),
**values** use `=` (as in the step DSL `{ name = ... }` and `key = expr`
arguments). The two parsers must not conflate them.

## 4. Control flow (v1)

- Sequential steps, plus `if`/`else`, `foreach`, and `par` (implemented in M8;
  see §4.1 for the design and §4.2 for scoping rules).
- Errors abort the workflow; the failing step is recorded and the run is
  resumable from that step.

### 4.1 `if` / `foreach` / `par`

Control-flow constructs are **value-producing** and use the same
`binder <- rhs @id` shape as step calls, so caching, tracing, and resume
(§8.1/§8.2) stay uniform:

- A block is a brace-delimited statement list with its own scope; its value is
  the value of its **last statement** (an empty block yields an empty record).
- `x <- if ${cond} { … } else { … } @id` requires `cond : Bool`. When the
  construct binds a value, the `else` branch is **mandatory** and both arms must
  have structurally-equal result types.
- `xs <- foreach v in ${list} { … } @id` and `xs <- par(max = N) v in ${list}
  { … } @id` require `list : List<T>`, bind `v : T` in the body scope, and
  produce `List<U>` where `U` is the body's tail type. `_ <-` discards the list
  (side-effect-only loop).
- `par` runs iterations with **bounded concurrency** (default 4, `par(max = N)`
  overrides), returns results in **input order** regardless of completion order,
  and aborts on the **lowest-index** failure. The trace writer serialises `emit`
  so `seq` numbering and on-disk line order stay consistent under concurrency.
- Resume correctness: each step inside a branch/loop is an ordinary cacheable
  step, but its step-key is **iteration/branch-scoped** — the executor threads a
  scope prefix (e.g. `check#2/c`, `mode?then/s`) into the key so dynamically
  distinct occurrences of the same static step get distinct keys. The scope is
  also threaded into **sub-workflow calls**: when a step at scope prefix `P`
  invokes a workflow or tool, the callee body runs with initial scope `P` (not
  `""`), so internal steps are call-site-prefixed (e.g. `check#2/c` before the
  callee's own `step-id`). This favours per-iteration resume correctness over
  cross-call cache sharing. The durable-workspace invariant (§8.2) therefore
  holds through loops/branches: a completed iteration's side effect is not
  re-applied on resume.
- Trace: `loop-start`/`loop-iter`/`loop-end` bracket each loop with its kind
  (`foreach`/`par`) and count; `if-branch` records the taken arm (§8.3.2).

### 4.2 Identifier scoping in control-flow blocks

**Status: decided — block-local scoping (v1).**

Each brace-delimited block is its own scope:

- Inner bindings do not escape the block (only the construct's own bind name,
  if any, is visible outside).
- Names from the enclosing scope are visible inside a block.
- **No shadowing:** an inner bind must not reuse a name already bound in an
  enclosing scope (§3.4).

Step `@id`s and control-flow construct `@id`s must be **unique within a block**.
Sibling `if` branches, unrelated loops, and nested blocks may reuse the same
static id; the executor disambiguates dynamically via the step-key scope prefix
(e.g. `mode?then/notify` vs `mode?else/notify`, `check#2/c`).

Rationale: mirrored branches and loops read naturally without inventing distinct
names for structurally identical steps; the scope-prefix machinery (§4.1) already
keeps cache keys and resume unambiguous.

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
3. Every `${...}` reference must resolve in the binding environment.
   In a bare position its type must match the target; in an interpolation
   position it is rendered per §3.2.1 (any type except `Bytes` and
   `Secret<_>`).
4. `@self#<heading>` is checked to exist in the current file; type `String`.
5. Return value:
   - If `outputs` is empty, no `return` is needed.
   - Otherwise an explicit `return { … }` block is required, **unless**
     the final step's result type is structurally equal to the `outputs`
     record — in which case the last bind is used implicitly. Because
     tool results are typically shaped like `{ text: String }` while
     `outputs` is shaped like `{ summary: String }`, the explicit form
     is the common case; the implicit form is a convenience for
     pass-through workflows only.
6. Cycles in the direct call graph across workflows are detected and
   rejected. Indirect references via `WorkflowRef` values are allowed.
7. Field access on a statically-typed `Record` is checked; access on an
   opaque `Json` value is **not** statically checked and may fail at
   runtime (see §8.3.2 `eval` errors). List indexing is never bounds-checked
   statically.
8. The checker is a pure function `Project -> Either [TypeError] TypedProject`
   so the same checker runs both at load time (`hwfi check`) and at runtime
   over dynamically synthesized workflows (see §13).
9. `builtin/llm-agent` / `builtin/llm-agent-object` (§6.1): every element of
   the `tools` argument must be a `ToolRef`/`WorkflowRef` value in scope,
   and every referenced callee must be **agent-eligible** — none of its
   declared inputs may be `Secret<_>`, `WorkflowRef`, `ToolRef`, or `Bytes`
   (§6.1.1), and it must not (transitively) call `builtin/introspect`
   (§6.1.5). Ineligible callees are rejected here, not at runtime. The round
   cap `max_rounds` is a static `Int` and must be ≥ 1. Model-driven call
   cycles (the model lets A call B which calls A) are bounded at runtime by
   `max_rounds`, not by the acyclic-call-graph rule of §5.6.6, which only
   covers *static* calls.

### 5.7 Environment access (`ctx.env`)

The `env` whitelist in `project.json` determines the fields of
`ctx.env`. v1 uses **strict presence**: every whitelisted variable must
be present in the process environment when `hwfi run` starts. A missing
whitelisted variable aborts startup before any step executes, with an
error naming the variable. Consequences:

- `ctx.env.<VAR>` has type `String` (or `Secret<String>` if the name
  matches the secret patterns in §5.5) and is **guaranteed present** —
  there is no `null`/`Option` case to handle, so string operations on it
  cannot fail at runtime for want of a value.
- v1 has no nullable/optional type. If future versions need "optional
  environment variable", that is an `Optional<T>` type addition
  (deferred, see §13), not a change to this strict default.
- This validation is distinct from provider-key validation (§7.3):
  provider keys are consumed by the runtime and are *not* required to be
  in the `env` whitelist.

## 6. Built-in tools (v1)

Provided by the engine, addressed as `builtin/<name>`:

- `builtin/read-file` : `{ path: FileRef } -> { text: String }`
- `builtin/write-file` : `{ path: FileRef, text: String } -> {}`
- `builtin/list-dir` : `{ path: FileRef } -> { entries: List<String> }`
- `builtin/read-file-slice` :
  `{ path: FileRef, offset: Int, limit: Int }
   -> { text: String, next_offset: Int, eof: Bool }` — line-windowed read
  for large files (offset/limit are 0-based line counts); see §6.2.
- `builtin/find-files` :
  `{ path: FileRef, glob: String } -> { paths: List<String> }` — list
  workspace files under `path` matching a glob; see §6.2.
- `builtin/grep` :
  `{ pattern: String, path: FileRef }
   -> { matches: List<Record<{ file: String, line: Int, text: String }>> }`
  — regex search over workspace files; see §6.2.
- `builtin/edit-file` :
  `{ path: FileRef, find: String, replace: String, expect: Int }
   -> { replacements: Int }` — replaces every non-overlapping literal
  occurrence of `find` with `replace`; `expect` (≥ 0) asserts the number of
  occurrences and the step **fails** if the actual count differs (guards
  blind edits). Mutating; see §6.2.
- `builtin/move-file` : `{ from: FileRef, to: FileRef } -> {}` — mutating.
- `builtin/copy-file` : `{ from: FileRef, to: FileRef } -> {}` — mutating.
- `builtin/remove-file` : `{ path: FileRef } -> {}` — mutating.
- `builtin/make-dir` : `{ path: FileRef } -> {}` — create a directory and
  any missing parents inside the workspace; mutating.
- `builtin/remove-dir` : `{ path: FileRef } -> {}` — remove a directory and
  its contents (recursively) inside the workspace; mutating.
- `builtin/exec` :
  `{ program: String, args: List<String>, stdin: String, timeout_ms: Int }
   -> { exit_code: Int, stdout: String, stderr: String, timed_out: Bool }`
  — run an allowlisted program in the workspace (§6.3, §7.5). Disabled
  unless `project.json.exec.allow` lists `program`. A non-zero exit is a
  **value**, not a run error, so a workflow (or agent) can react to it.
- `builtin/llm-generate` : `{ system: String, prompt: String, model: String }
  -> { text: String }` (single-shot; backed by `llm-simple`
  `Generate.generateTextWithFallbacks`)
- `builtin/llm-chat` :
  `{ system: String,
     messages: List<Record<{ role: String, content: String }>>,
     model: String } -> { text: String }` — multi-turn generation for
  agentic loops, where `messages` is an ordered chat history
  (`role ∈ {"user","assistant","tool"}`, validated at runtime). Maps to
  `llm-simple`'s message-based `GenRequest`. Prefer this over encoding a
  whole conversation into a single `prompt` string.
- `builtin/llm-gen-object` : `{ system: String, prompt: String, schema: Json,
  model: String } -> { value: Json }` (backed by `genObject` /
  `genObjectUntyped`)
- `builtin/introspect` : `{} -> { data: Json }` — escape hatch returning a
  JSON dump of everything the runtime knows about the current run
  (including full trace, all bindings, workspace path, project metadata).
  Marks the calling step non-cacheable (§8.2).
- `builtin/llm-agent` :
  `{ system: String, prompt: String, model: String,
     tools: List<ToolRef<_, _> | WorkflowRef<_, _>>,
     max_rounds: Int } -> { text: String, rounds: Int }` — an
  **LLM-driven** step: the model is advertised the given tools and
  autonomously issues tool calls in a loop (each backed by a declared hwfi
  tool/sub-workflow, run through the normal executor) until it produces a
  final free-text answer or `max_rounds` is reached. See §6.1.
- `builtin/llm-agent-object` :
  `{ system: String, prompt: String, model: String,
     tools: List<ToolRef<_, _> | WorkflowRef<_, _>>,
     schema: Json, max_rounds: Int } -> { value: Json, rounds: Int }` — the
  typed-output variant of `builtin/llm-agent`. The model may call tools to
  gather information, then must terminate by calling a synthesized `submit`
  tool whose parameters are `schema` (§6.1.3). `builtin/llm-gen-object` is
  the zero-tool degenerate case of this builtin.

For all LLM tools, `model` names an entry in the **model catalog** (§7.3),
not a raw provider model id. Retry, timeout, temperature, and pricing
metadata come from the catalog entry, not from tool arguments.

`builtin/llm-agent` and `builtin/llm-agent-object` mark the calling step
non-cacheable as a black box, but each internal model call and tool call is
individually content-addressed so a crash mid-loop resumes cheaply (§8.2).

The filesystem-mutation tools (`edit-file`, `move-file`, `copy-file`,
`remove-file`, `make-dir`, `remove-dir`) and `exec` exist so that
prompt-authored workflows — and agents (§6.1) — can **modify the
workspace**, e.g. to write and test code. They are ordinary cacheable
builtins (§8.1) and rely on hwfi's durable-workspace resume invariant
(§8.2): a cache hit means "this effect is already present in the
workspace." All of them are eligible to be advertised as agent tools
(§6.1.1) — that is the point of adding them.

### 6.1 Agentic tool-use loop (`builtin/llm-agent`)

Where `builtin/llm-generate`/`-chat`/`-gen-object` are *workflow-driven*
(the workflow orchestrates and the model is called one-shot per step; it
never decides to call anything), `builtin/llm-agent` is *LLM-driven*:
within a single step the model is handed a set of callable tools and
autonomously issues tool calls in a loop until it yields a final answer.
The tools it may call are **the project's own declarations**, so a
prompt-authored workflow can expose e.g. `tools/search` and
`workflows/extract` to a model and let the model decide when to use them.

The full design rationale (and the prior art it draws on) is in
[tool-use.md](tool-use.md); this section pins the normative behaviour.

Loop semantics:

1. **Advertised tools.** The `tools` argument is a list of first-class
   `ToolRef`/`WorkflowRef` values (§5.1). Each is resolved to its
   declaration and exposed to the provider as a tool whose JSON-Schema
   parameters are derived from the callee's declared inputs (§6.1.1).
2. **Rounds.** Each round the model is called with the conversation so far
   and the advertised tools. If it emits one or more tool calls, the engine
   runs each targeted ref through the normal executor as a nested step
   (§6.1.2), serialises each typed result back to JSON, appends it as a
   tool message, and starts the next round. If it emits a final answer with
   no tool calls (or, for `builtin/llm-agent-object`, a `submit` call,
   §6.1.3), the loop ends.
3. **Round cap.** `max_rounds` bounds the number of model rounds. Reaching
   it without termination aborts the step with an `Error` of kind `llm`
   (§8.3.2). `max_rounds` must be ≥ 1.
4. **Result.** `builtin/llm-agent` returns `{ text, rounds }`, where `text`
   is the model's final free-text answer and `rounds` is the number of
   model rounds executed. `builtin/llm-agent-object` returns
   `{ value, rounds }`, where `value` is the decoded `submit` payload.

#### 6.1.1 Signature → JSON-Schema translation

Each advertised ref is turned into a provider tool whose parameter schema
is a total translation of the callee's resolved input types
(`inputs : Map<Ident, TypeExpr>`) into JSON Schema:

| hwfi type                         | JSON Schema                              |
|-----------------------------------|------------------------------------------|
| `String`                          | `{"type":"string"}`                      |
| `Int`                             | `{"type":"integer"}`                     |
| `Double`                          | `{"type":"number"}`                      |
| `Bool`                            | `{"type":"boolean"}`                     |
| `FileRef`                         | `{"type":"string"}` (workspace path)     |
| `List<T>`                         | `{"type":"array","items": T}`            |
| `Record<{…}>`                     | `{"type":"object","properties": …, "required": …}` |
| `Json`                            | unconstrained (`{}`)                     |
| type-alias qname                  | schema of the resolved alias             |

The following input types make a callee **ineligible** as an agent tool
and are rejected at `hwfi check` (§5.6):

- `Secret<_>` — must never be model-supplied or exposed to the model (§5.5).
- `WorkflowRef<_, _>` / `ToolRef<_, _>` — refs are not model-supplied.
- `Bytes` — no implicit text/JSON encoding (cf. §3.2.1).

The same translation drives the `submit` tool of §6.1.3, applied to the
`schema` argument of `builtin/llm-agent-object`.

#### 6.1.2 Tool calls run through the executor

When the model emits `ToolCall { name, arguments }`:

1. `name` is resolved to one of the advertised refs. An **unknown** name is
   a *recoverable* error: the engine appends a tool message describing the
   error and continues the loop (the model may retry). It is **not** a run
   abort.
2. `arguments` (a JSON object) is coerced into the callee's declared input
   types via the same `coerceFromJson` used to reconstruct inputs on resume.
   A parse/type failure is likewise recoverable — fed back as a tool
   message, not a run abort.
3. The callee is run through `Hwfi.Runtime.Executor` as a **nested step**,
   so its `step-start`/`step-end`, `llm-call`, and `file-io` events nest
   under the agent step (§8.3.3.6) and its effects go through the sandboxed
   `Workspace` (§7.1). The model never touches the filesystem directly.
4. The result `RValue` is serialised to **redacted** JSON as the tool-message
   content for the next round (§8.3.4). Intra-step tool-call caches store this
   same redacted form so resume replays exactly what the model originally saw;
   secrets in a tool result therefore appear as `<secret:…>` to the model on
   both the fresh and resume paths. Scripted (non-agent) steps cache the actual
   `RValue` instead (§8.1).

#### 6.1.3 Terminating `submit` tool for typed output

`builtin/llm-agent-object` synthesizes an extra `submit` tool from its
`schema` argument (§6.1.1) and advertises it alongside the caller's tools:

- **Calling `submit` ends the loop**, and its arguments — coerced against
  `schema` — become the step's `value`.
- **`submit` is mandatory.** Finishing with plain text instead of a
  `submit` call is a hard error (`llm` kind). (This is what makes the typed
  variant type-safe; the free-text `builtin/llm-agent` has no `submit` and
  terminates on a text answer.)
- A **decode failure** of the `submit` arguments is *recoverable*: it is
  returned to the model as a tool message so it can correct itself and call
  `submit` again — not a run abort.

`submit` must be called on its own. The engine advertises this in the
tool's description, and enforces it: a round that mixes `submit` with other
tool calls is **rejected** — the engine feeds back a tool message telling
the model to call `submit` alone, and runs none of that round's calls. This
avoids executing side-effecting tools whose results the model would never
see (see [tool-use.md](tool-use.md) §3.3).

#### 6.1.4 Error posture

The agent loop introduces a **localized, recoverable error boundary**
inside the step, which does not change the global "abort on first error"
posture (§4, §13). Failures are classified:

- **Recoverable** (turned into a tool message; loop continues): unknown
  tool name, malformed/ill-typed tool arguments, a tool result the callee
  itself surfaces as an error, and `submit` decode failures.
- **Fatal** (abort the run with an `Error` event): `max_rounds` exhaustion,
  provider/auth/generation failures (`llm`), lost workspace lock, and any
  `internal` engine fault.

#### 6.1.5 Sandbox, secrets, and readonly

- Every model-chosen call is routed through the executor, so workspace
  path-traversal protection (§7.1) and `file-io` tracing hold with no
  special casing. `llm-simple`'s own filesystem tools are **not** exposed.
- `Secret<_>` inputs are never model-supplied or interpolated (§5.5),
  enforced at type-check (§6.1.1, §5.6).
- `builtin/introspect` must not be reachable as an agent tool: it would
  hand the whole run (including the full trace) to the model's context.
  Passing a callee that (transitively) calls `builtin/introspect` as an
  agent tool is rejected at `hwfi check`.

### 6.2 Filesystem mutation and navigation tools

The read (`read-file`, `list-dir`, `read-file-slice`, `find-files`,
`grep`) and mutation (`write-file`, `edit-file`, `move-file`,
`copy-file`, `remove-file`, `make-dir`, `remove-dir`) builtins all
resolve their `FileRef` arguments through the **same** workspace guard as
`read-file`/`write-file` (§7.1): every path is resolved lexically against
the canonical workspace root, rejected if it is absolute or escapes the
root via `..`, then **canonicalised** and verified to remain under the
workspace root (so symlinks cannot redirect reads or mutations outside).
`find-files`/`grep` directory walks skip symlinked entries rather than
following them. There is exactly one sandbox, one `file-io` trace event stream
(§8.3.2), and one cache/fingerprint scheme for all of them.

**Implementation note (native, not wrapped).** These are implemented
directly against `Hwfi.Runtime.Workspace`; `hwfi` does **not** wrap
`llm-simple`'s `LLM.Tools.*` / `TypedTool` implementations. Wrapping them
would route file access through a second, weaker sandbox
(`LLM.Tools.FsConfig`, whose own docs note an unclosed TOCTOU window) and
bypass hwfi's `file-io` tracing, secret redaction, and step-key
fingerprinting. Where a non-trivial algorithm is worth reusing (glob
matching, binary-file detection, size caps, regex search), its **pure
logic** may be ported, but the effectful shell is hwfi's. See
[tool-use.md](tool-use.md) §8 for the rationale.

Semantics worth pinning:

- `edit-file` performs a literal (non-regex) whole-string replacement of
  `find`. `expect` is the caller's asserted occurrence count; a mismatch
  fails the step with an `eval` error rather than silently editing the
  wrong number of sites. This makes model-driven edits auditable.
- `grep` uses the same regex dialect as the `Grep` tool used elsewhere in
  the toolchain (RE2-style); a malformed pattern is an `eval` error.
- `read-file-slice` returns a window of `limit` lines starting at line
  `offset` (0-based), plus the `next_offset` to continue from and whether
  end-of-file was reached, so an agent can page through a file larger than
  a single tool result.
- `remove-dir` is recursive but confined to the workspace; like all
  mutations it cannot affect the read-only project directory (§7.1).
- Reads that hit a binary file or exceed the byte cap fail as an `io`
  error (v1 is text-only, §12), consistent with `read-file`.

All of these are **cacheable** ordinary builtins (§8.1). Their resume
behaviour is governed by the durable-workspace invariant (§8.2): a cache
hit means the effect (or observation) is already reflected in the
workspace as the interrupted attempt left it, so it is not re-applied.

### 6.3 Command execution (`builtin/exec`)

`builtin/exec` runs an external program so that workflows and agents can
build, test, format, or otherwise operate on the code in the workspace.
It is the one built-in with authority beyond the filesystem, so it is
governed by an explicit, opt-in policy (§7.5) and is **disabled unless
`project.json` declares an `exec` policy** whose `allow` list contains the
requested `program`.

- **argv, not a shell.** `exec` takes a `program` basename and an explicit
  `args : List<String>`. It does **not** run a shell (`sh -c`), so there
  is no shell-word-splitting, globbing, or injection surface: arguments are
  passed verbatim. (A workflow that genuinely wants shell semantics must
  allowlist a shell and pass `["-c", "…"]` deliberately.)
- **Working directory** is the workspace root (§7.1). `program` is looked
  up on the policy-provided `PATH`; a relative/absolute path for `program`
  is rejected — only allowlisted basenames run.
- **Environment** is empty except for the variables named in
  `project.json.exec.env`. Provider API keys are never injected.
- **Non-zero exit is a value.** The result carries `exit_code`, captured
  `stdout`/`stderr` (each truncated to `max_output_bytes`, with
  `timed_out` set if the wall-clock `timeout_ms` fired). A failed build is
  therefore something an agent can read and react to, not a run abort.
  Genuine engine-level failures (program not allowlisted, spawn failure)
  are fatal `sandbox`/`io` errors.
- **Determinism / caching.** `exec` is a cacheable builtin keyed like any
  step (§8.1) and, as an agent tool call, sub-keyed per §8.2.1. On resume,
  a cache hit **replays the recorded `exit_code`/output without re-running
  the command**, which (a) keeps an agent's nondeterministic loop on the
  same branch it originally took and (b) avoids re-paying an expensive
  build/test. Its file effects are covered by the durable-workspace
  invariant (§8.2). The key hashes `program`, `args`, `stdin`, and the ctx
  projection — **not** the current contents of the workspace; the standard
  "resume assumes the workspace is as the interrupted run left it" caveat
  (§8.2) applies, exactly as it already does to `read-file`.

Because `exec` output is fed back to the model when used as an agent tool,
it participates in redaction (§8.3.4) and tracing (§8.3.2, the `exec`
event) like every other tool.

## 7. Workspace, project, and sandboxing

### 7.1 Filesystem layout at runtime

- Engine receives `--workspace <dir>` on the CLI.
- All `FileRef` values are resolved relative to the workspace root.
- The workspace root is canonicalised once at startup (`newWorkspace`).
- **Path resolution (two stages).**
  1. *Lexical:* collapse `.` / `..` and reject absolute paths or any `..`
     that would escape the root (A5).
  2. *Containment:* `canonicalizePath` the result and verify its canonical
     prefix is the workspace root. Reject if not — including when a path
     component is a symlink that points outside the workspace. All direct
     file operations (`read-file`, `write-file`, mutation builtins) use
     both stages before touching the filesystem.
- Directory walks (`find-files`, `grep`) skip symlinked entries at each
  level rather than following them.
- The workspace is the **only** filesystem area the workflow may write to.
  Every read and mutation builtin (§6.2) and every `builtin/exec` child
  (§6.3, §7.5) is confined to it by the same guard; there is no second
  sandbox.
- The project directory (workflows/tools/types/project.json) is read-only
  during execution.

### 7.2 Provider API keys and `.env`

`hwfi` does not use `llm-simple`'s `LLM.Load.loadGateways`. Instead, it
constructs provider gateways itself from the `LLM.Providers.*` modules,
using its own key store. This avoids relying on the process working
directory and keeps API keys typed as `Secret Text` throughout the
engine.

Key sources, in order of precedence (highest wins):

1. File named by `--env-file <path>` on the CLI, if given.
2. `<project>/.env`, if the file exists.
3. The existing process environment (`OPENAI_API_KEY` etc. exported by
   the user's shell or a wrapper like `direnv`).

`.env` files are parsed with `Configuration.Dotenv.parseFile`, which
returns key/value pairs **without** injecting them into the process
environment. `hwfi` merges the sources into an internal `KeyStore ::
Map ProviderName (Secret Text)`. A missing `.env` at levels 1 or 2 is
never an error on its own — only a missing key that is actually
required by the effective model catalog (§7.3) fails startup.

Recognised provider keys:

| Provider  | Env var             |
|-----------|---------------------|
| openai    | `OPENAI_API_KEY`    |
| claude    | `CLAUDE_API_KEY`    |
| gemini    | `GEMINI_API_KEY`    |
| deepseek  | `DEEPSEEK_API_KEY`  |
| ollama    | *(no key required)* |

Semantics:

- Provider API keys never appear in `ctx.env` and are never observable
  by workflows. They live in gateway closures inside the runtime.
- The `env` whitelist in `project.json` only governs what workflows can
  read via `ctx.env`. Adding `OPENAI_API_KEY` to the whitelist would
  make it readable by workflow code — do not do this unless you
  intentionally want the key visible to steps (see §5.5 for how such
  values would be redacted in traces).
- `hwfi` does **not** change the process working directory. Relative
  paths on the CLI are resolved against the shell's cwd, as expected.

### 7.3 Model catalog

Every project **must** provide a `model-catalog.json` at its root. There
is no engine-bundled default. Rationale:

- The catalog is a manifest of the project's LLM dependencies (which
  provider, which model id, retry/timeout/temperature/pricing). Making
  it explicit matches the typed-workflow ethos and avoids the "why did
  my workflow break when the engine updated its default catalog"
  problem.
- Missing `model-catalog.json` fails at `hwfi check` with a clear
  message.

The catalog format is the JSON schema defined by `llm-simple`:

```
[
  { "modelConfigName": "gpt_4_1",
    "providerName":    "openai",
    "modelName":       "gpt-4.1",
    "pricing": { "pricePerMillionInput": ..., "pricePerMillionOutput": ... },
    "maxTokens": 8192, "temperature": 0.5,
    "requestTimeout": 30000, "throttleDelay": 500,
    "retryCount": 3, "jitterBackoff": 1000
  },
  ...
]
```

The `model` argument to `builtin/llm-*` must name an entry
(`modelConfigName`) in the catalog. Unknown names fail at runtime with a
clear error listing available names (A11).

Editing a catalog entry (provider model id, temperature, token cap,
timeouts, retry policy) must change the **model-catalog fingerprint**
used in step-key hashing (§8.1) and agent intra-step model sub-keys
(§8.2.1), so cached one-shot LLM step results are invalidated on
`hwfi resume` after a catalog change.

Provider–key linking is validated at startup: for every model referenced
in the catalog, the corresponding provider key must be available from
the sources in §7.2 (except `ollama`, which requires no key). Missing
keys fail startup with:

```
error: model 'gpt_4_1' in model-catalog.json requires provider 'openai',
  but OPENAI_API_KEY was not found in --env-file, <project>/.env, or the
  process environment.
```

### 7.4 Network access

`hwfi` itself makes no network calls except `llm-simple` calls invoked by
`builtin/llm-*`; there is no arbitrary HTTP tool in v1. Note that
`builtin/exec` (§6.3, §7.5) can run a program that itself performs network
I/O (e.g. `git fetch`, a package install). This is an inherent consequence
of command execution: the `exec` allowlist in `project.json` is the
control point — a project that must forbid network access should not
allowlist network-capable programs. `hwfi` does not attempt per-process
network sandboxing in v1.

### 7.5 Command execution sandbox

`builtin/exec` (§6.3) is governed entirely by the optional `exec` policy in
`project.json` (§2). The policy is **fail-closed**: with no `exec` block,
or an empty `allow` list, any `builtin/exec` call is rejected at
`hwfi check` (a `sandbox` category check error), so a project cannot run
commands unless it opts in.

Enforcement rules:

- **Program allowlist.** Only a program whose basename is in
  `exec.allow` may run. `program` must be a bare basename (no `/`); an
  absolute or relative path is rejected. Resolution uses the policy `PATH`.
- **Working directory** is the canonical workspace root; the child cannot
  be given a different cwd.
- **Environment.** The child receives only the variables named in
  `exec.env` (read from `hwfi`'s process environment), never provider API
  keys or the full ambient environment.
- **Resource limits.** Each call is bounded by `timeout_ms` (the call's
  argument, else the policy default) and each captured stream is truncated
  to `max_output_bytes`. Exceeding the timeout kills the process group and
  returns `timed_out = true` with whatever output was captured.
- **Auditing.** Every call emits an `exec` trace event (§8.3.2) recording
  `program`, `args`, `exit_code`, `timed_out`, and captured byte sizes;
  secrets are redacted per §8.3.4.

Known v1 limitations (documented, not silently accepted): `hwfi` relies on
the allowlist and empty environment rather than OS-level containment
(namespaces/seccomp). A determined allowlisted program can still exhaust
CPU/disk or reach the network (§7.4). Projects that need stronger
isolation should run `hwfi` inside their own container/VM. Stronger
per-process sandboxing is a possible later refinement.

### 7.6 Runtime process (RTS)

The `hwfi` executable and its test suite must be linked with the **threaded**
RTS (`ghc-options: -threaded`) and run with multiple capabilities by default
(`-with-rtsopts=-N`), because the engine uses bounded concurrency (`par`),
subprocess execution with wall-clock timeouts, and concurrent LLM calls. On
the single-threaded RTS, green threads do not run in parallel and any
blocking **safe** FFI call (e.g. DNS during HTTP) stalls the entire process,
which can make `par` appear to hang.

## 8. Persistence and resumability

Every run has a `run id` (ULID). Run artifacts are stored under
`<workspace>/.hwfi/runs/<run-id>/`:

```
run.json          # run metadata: project hash, entrypoint, inputs, status
steps/
  <step-key>.json # one file per completed cacheable step
trace.jsonl       # append-only event log
```

### 8.1 Step-key hashing

```
step-key = hash( qname,
                 step-id,
                 resolved-args,
                 ctx-projection,
                 callee-fingerprint )
```

**Declaration fingerprint (Merkle over the call graph).** Each workflow
and tool has a fingerprint:

```
fingerprint(d) = hash( normalized-AST(d),
                       [ fingerprint(c) | c <- sorted direct-callees(d) ] )
```

- `normalized-AST(d)` is the parsed declaration with source positions,
  comments, and insignificant whitespace stripped, plus the declaration's
  frontmatter signature.
- Direct callees are the qnames a declaration statically calls. Because
  the direct call graph is acyclic (§5.6.6), this recursion terminates.
- `callee-fingerprint` in the step-key is `fingerprint(callee)` of the
  step's `call` target. Editing the called tool/sub-workflow — or
  anything it transitively calls — changes the fingerprint and therefore
  the step-key, so **cached results are correctly invalidated when code
  changes** across an abort/resume boundary.
- When an argument value is a `WorkflowRef`/`ToolRef`, its contribution
  to `resolved-args` is the referenced declaration's `fingerprint`, not
  merely its qname, so passing an edited workflow as a value also
  invalidates correctly.

Built-in tools (`builtin/*`) have a fixed fingerprint derived from the
engine version.

**Model-catalog fingerprint (LLM builtins).** For cacheable one-shot LLM
builtins (`builtin/llm-generate`, `builtin/llm-chat`, `builtin/llm-gen-object`),
the step-key must also incorporate a fingerprint of the resolved catalog
entry named by the `model` argument — the same scalar fields as
`model-catalog-fingerprint` in §8.2.1 (`modelConfigName`, provider model id,
`maxTokens`, `temperature`, `requestTimeout`, `throttleDelay`, `retryCount`,
`jitterBackoff`). The model *name* string alone in `resolved-args` is not
sufficient: repointing `fast` at a different underlying model or changing
temperature must bust the cache. Agent steps already fold this fingerprint
into intra-step model sub-keys (§8.2.1); one-shot builtins must do the
equivalent at the step-key level (e.g. as an extra `ctx-projection` line or
a sixth hash component).

**Ctx projection.** `ctx-projection` includes only those `ctx.*` fields
the step actually references, restricted to *stable* fields:

- Stable: `ctx.workspace`, `ctx.run.id`, `ctx.self.qname`, `ctx.self.step_id`,
  `ctx.inputs.*`, `ctx.env.*`.
- Volatile: `ctx.trace`, `ctx.run.started_at`, and anything reachable via
  `builtin/introspect`.

A step that references any volatile `ctx` field, or calls
`builtin/introspect`, is **non-cacheable** and is always re-executed on
resume. This is statically decidable at type-check time and recorded on
the AST node.

An agent step (`builtin/llm-agent` / `builtin/llm-agent-object`, §6.1) is
**also non-cacheable as a whole**: its behaviour — which tools it calls, in
what order, with what arguments — is chosen by the model and is not a
function of its resolved arguments, so it cannot be a cacheable black box.
`classifyCacheable` treats it like `builtin/introspect`. Its *internal*
units are cached instead (§8.2.1).

### 8.2 Resume semantics

- Cacheable steps: skipped on resume if their `step-key` has a persisted
  result. A skipped step emits **no new trace events**; its original
  events from the earlier attempt remain in `trace.jsonl` and continue to
  represent it (see §8.3.5).
- Non-cacheable steps: always re-executed. Rationale: their whole purpose
  is to observe the current trace or environment, so replaying with cached
  output would defeat the point.
- A step is atomic: partial LLM output is not resumed mid-call. A step
  whose `StepStart` was written but which crashed before a terminal event
  has no persisted result, so it is re-executed on resume.
- On resume the runtime appends one `Resumed` marker (§8.3.2) before any
  new events, then continues numbering `seq` from the last value + 1.
- A run is resumable if `run.json.status ∈ {running, crashed, aborted}`.
- **Crash handling.** Typed `RuntimeError` values end a run deliberately
  (`run-end` with `status: aborted`, `run.json.status: aborted`). An
  **unexpected synchronous exception** (provider library fault, aeson bug,
  unhandled I/O, etc.) must also be handled deliberately: emit a terminal
  `error` event (`kind: internal`), append `run-end` with `status: crashed`,
  set `run.json.status` to `crashed`, then rethrow or exit. A run must not
  be left at `status: running` with no `run-end` after a crash. `crashed`
  runs remain resumable like `aborted` ones.

**Durable-workspace invariant.** Resume treats the workspace directory as
**durable state carried over from the interrupted attempt**. A cache hit
therefore means "this step's effect is already present in the workspace"
(for a mutation like `write-file`/`edit-file`/`move-file`/`exec`) or "this
observation was valid as of the interrupted attempt" (for a read like
`read-file`/`grep`). Consequently:

- A cached **mutating** step is skipped and its effect is **not
  re-applied** — this is exactly why A4 (a marker-writing step must not
  double-write on resume) holds, and it extends unchanged to the new
  mutation builtins (§6.2) and to `exec` (§6.3).
- A cached **read/exec** step replays its recorded result rather than
  re-reading/re-running, so an agent loop follows the same branch
  deterministically (§8.2.1).
- The step-key hashes arguments and the ctx projection, **not** the live
  contents of the workspace. If the workspace is mutated out-of-band
  between the interrupted attempt and `hwfi resume`, cached reads/execs may
  no longer match reality. This is the same, already-documented assumption
  that governs `read-file` today; it is a property of content-addressing
  by inputs, not a new risk introduced by mutation/exec.

### 8.2.1 Intra-step caching of agent loops

An agent step is non-cacheable as a whole (§8.1), but re-running the
**entire** loop on resume — re-issuing every model call (cost) and
re-executing every tool call (side effects like `builtin/write-file`) —
is unacceptable. Therefore the loop's internal units are **individually
content-addressed and cached**, reusing the existing store (`RunStore`'s
`cacheStepResult` / `lookupCachedResult`; the sub-keys are just more
entries under `steps/`, so no new storage layer is needed). This is a
requirement, not an optimization.

Two kinds of unit are cached under the enclosing agent step-key:

- **Tool calls** (each model-chosen call is a nested step, §6.1.2):
  `hash(agent-step-key, round-index, call-index-in-round,
  callee-fingerprint, canonical(resolved-args))`. `call-index-in-round`
  disambiguates multiple tool calls in one assistant turn (provider order
  is stable). `submit` is just another tool call and needs no special
  handling.
- **Model calls** (each round's generation):
  `hash(agent-step-key, round-index, canonical(messages-so-far),
  model-catalog-fingerprint, advertised-tools-fingerprint)`. The
  `messages-so-far` already encode every prior round's assistant turn and
  tool results, so the key chain is self-consistent.

**Canonicalization caveat.** Sub-keys hash the **actual** message content
and resolved args (as stored in `steps/*.json`, non-redacted, §8.3.4 /
STATUS notes), never the trace's `redactedJson` form, and use
`canonicalJson` so turn ordering, tool-result serialisation, and JSON
field order do not perturb the key. Any instability here silently turns
cache hits into misses on resume.

**Resume behaviour.** The loop re-drives from round 0 but consults the
cache (only on resume, per §8.2):

- Each model call: on a hit, reuse the cached assistant turn *including the
  tool calls it chose*, without paying the provider — this makes the
  nondeterministic replay follow the **same branch** deterministically.
- Each tool call: on a hit, reuse the cached result without re-running its
  side effects.
- A miss anywhere re-runs from that point; every downstream sub-key then
  changes and re-runs too — exactly the existing "cacheable ⇒ skip, else
  re-run" rule applied one level down.

Because a cached replay does no provider calls and no side effects (only
re-walks the loop, hashing and looking up), serialising the loop's
in-memory state to disk is a *possible later optimization*, not a
prerequisite for correct, cheap resume.

### 8.3 Trace event schema

`trace.jsonl` is append-only, one JSON object per line. Each object is
a tagged variant of `TraceEvent`. The same ADT is exposed to workflows
via `ctx.trace : List<TraceEvent>` (§5.2), so agents can pattern-match
on events. This is a load-bearing API surface — the shape below is
stable across v1.

#### 8.3.1 Common fields

Every event carries:

| Field   | Type       | Notes                                                |
|---------|------------|------------------------------------------------------|
| `tag`   | `String`   | Discriminator; one of the values listed below.       |
| `seq`   | `Int`      | Monotonic per-run counter, starts at 0.              |
| `at`    | `String`   | UTC ISO-8601 with millisecond precision, `Z` suffix. |

Events that occur inside a step also carry:

| Field     | Type     | Notes                                             |
|-----------|----------|---------------------------------------------------|
| `qname`   | `String` | Fully-qualified name of the enclosing workflow.   |
| `step_id` | `String` | Step id within that workflow.                     |

#### 8.3.2 Variants

```
TraceEvent =
  | RunStart {
      tag          : "run-start",
      seq, at,
      run_id       : String,
      entrypoint   : String,       -- qname of entry workflow
      inputs       : Json,         -- root inputs, secrets redacted
      project_hash : String        -- content hash of the project dir
    }
  | StepStart {
      tag        : "step-start",
      seq, at, qname, step_id,
      args       : Json,           -- resolved args, secrets redacted
      cacheable  : Bool            -- static classification (§8.1)
    }
  | StepEnd {
      tag         : "step-end",
      seq, at, qname, step_id,
      result      : Json,          -- secrets redacted
      duration_ms : Int
    }
  | LlmCall {
      tag        : "llm-call",
      seq, at, qname, step_id,
      model      : String,
      system     : String,         -- may be redacted per §5.5
      prompt     : String,         -- may be redacted per §5.5
      response   : String,         -- may be redacted per §5.5
      tokens_in  : Int,
      tokens_out : Int
    }
  | FileIo {
      tag     : "file-io",
      seq, at, qname, step_id,
      op      : "read" | "write" | "list"
              | "read-slice" | "find" | "grep"
              | "edit" | "move" | "copy" | "remove"
              | "make-dir" | "remove-dir",
      path    : String,            -- workspace-relative (the primary path;
                                   --   for move/copy this is the source)
      bytes   : Int                -- payload size; 0 where not meaningful
    }
  | Exec {
      tag        : "exec",
      seq, at, qname, step_id,
      program    : String,         -- allowlisted basename
      args       : Json,           -- argv, secrets redacted
      exit_code  : Int,
      timed_out  : Bool,
      stdout_bytes : Int,          -- captured (post-truncation) sizes
      stderr_bytes : Int
    }
  | Error {
      tag     : "error",
      seq, at, qname, step_id,
      message : String,
      kind    : "type" | "eval" | "io" | "sandbox"
              | "llm" | "user" | "internal"
    }
  | AgentRoundStart {
      tag     : "agent-round-start",
      seq, at, qname, step_id,
      round   : Int                -- 0-based round index within the step
    }
  | AgentToolCall {
      tag        : "agent-tool-call",
      seq, at, qname, step_id,
      round      : Int,
      call_index : Int,            -- index of this call within the round
      tool       : String,         -- resolved ref qname (or "submit")
      args       : Json            -- decoded call args, secrets redacted
    }
  | AgentToolResult {
      tag        : "agent-tool-result",
      seq, at, qname, step_id,
      round      : Int,
      call_index : Int,
      tool       : String,
      result     : Json,           -- serialised tool result, secrets redacted
      recoverable_error : Bool     -- true if this result is a fed-back error
    }
  | AgentRoundEnd {
      tag      : "agent-round-end",
      seq, at, qname, step_id,
      round    : Int,
      finished : Bool              -- true if the model terminated this round
    }
  | Resumed {
      tag      : "resumed",
      seq, at,
      run_id   : String,
      from_seq : Int               -- last seq of the interrupted attempt
    }
  | RunEnd {
      tag    : "run-end",
      seq, at,
      run_id : String,
      status : "completed" | "aborted" | "crashed"
    }
```

`kind` values: `type` (should not occur at runtime for statically-checked
code), `eval` (expression evaluation failure — list index out of bounds,
missing field on an opaque `Json` value, interpolation of an unexpected
runtime value), `io` (filesystem), `sandbox` (workspace-boundary
violation), `llm` (provider/generation failure), `user` (error raised by
workflow logic itself), `internal` (engine bug).

#### 8.3.3 Ordering and correlation invariants

A trace represents one *logical run*, which may span several execution
*attempts* separated by `Resumed` markers.

1. The file begins with exactly one `RunStart`. Each resume appends
   exactly one `Resumed` marker. When the logical run reaches a terminal
   state it ends with exactly one `RunEnd` (`status ∈ {completed,
   aborted, crashed}`). The engine writes `run-end` on both typed aborts
   (`aborted`) and unexpected exceptions (`crashed`, §8.2). A run killed
   without running the crash handler (e.g. `SIGKILL`) may have no `RunEnd`;
   resumability is determined by `run.json.status`, not solely by the
   presence of `RunEnd`.
2. `seq` is strictly increasing across the whole file and gap-free,
   continuing across attempts.
3. Within a single attempt (the events between one `RunStart`/`Resumed`
   and the next `Resumed`/`RunEnd`), each executed step's `StepStart` is
   followed by exactly one terminal event — `StepEnd` (success) or
   `Error` (failure) — matched by `(qname, step_id)`. A `StepStart` left
   without a terminal before a `Resumed` marker denotes a step
   interrupted by crash; it is retried in the next attempt. Consequently
   a given `(qname, step_id)` may recur across attempts.
4. On resume, a cacheable step served from cache emits **no** events;
   its original `StepStart` / inner / `StepEnd` from the earlier attempt
   already exist earlier in the file.
5. `LlmCall` and `FileIo` events occur strictly between their step's
   `StepStart` and its terminal event, tagged with the same
   `(qname, step_id)`.
6. Sub-workflow calls nest: the callee's events appear between the
   caller's `StepStart` and terminal. Consumers reconstruct the call tree
   from `(qname, step_id)` chronology within an attempt.
7. An agent step (§6.1) emits, between its `StepStart` and terminal, one
   `AgentRoundStart`/`AgentRoundEnd` pair per model round (with strictly
   increasing `round`), and within a round zero or more
   `AgentToolCall`/`AgentToolResult` pairs matched by `(round,
   call_index)`. Each round's model generation appears as an `LlmCall`
   between its `AgentRoundStart` and the round's first tool call (or
   `AgentRoundEnd`). Each tool call runs a nested step (§6.1.2), so that
   callee's own `StepStart`/inner/`StepEnd` events appear between the
   corresponding `AgentToolCall` and `AgentToolResult`. On resume, model
   calls and tool calls served from the intra-step cache (§8.2.1) emit no
   new events; their original events remain earlier in the file.

#### 8.3.4 Redaction

Any field whose statically-inferred type contains `Secret<_>` is
replaced with the string `"<secret:$name>"` on serialisation, where
`$name` is the source binding name if known, otherwise `?`. Redaction
happens once, at the writer, before the line is appended.

`Secret<_>`-typed values in `args`, `result`, `system`, `prompt`,
`response`, and in the `args`/`result` of `AgentToolCall`/`AgentToolResult`
are redacted per §5.5.

#### 8.3.5 `ctx.trace` construction

At the moment a step begins executing, `ctx.trace` is the ordered parse
of `trace.jsonl` exactly as persisted so far — every real event of the
logical run across all attempts, including `Resumed` markers.

This makes the observed history **independent of caching**: because a
cached upstream step contributes its *original* detailed events (which
remain in the file) rather than a synthetic placeholder, a downstream
step reading `ctx.trace` sees the same `LlmCall`/`FileIo`/`StepEnd`
events whether or not the upstream step was re-executed on this attempt.
A workflow's behaviour therefore does not change depending on where a
crash happened to occur.

Consumers that want per-attempt segmentation can split on `Resumed`
markers; consumers that want the logical-run view can ignore them.

## 9. CLI

Binary name: `hwfi`. Minimal v1 surface:

```
hwfi check   <project-dir>
hwfi run     <project-dir> --workspace <dir>
             [--env-file <path>]
             [--input <k>=<v>]... [--input <k>=@<file.json>]...
             [--input-json <file.json>]
             [--entry <qname>]
hwfi resume  <workspace-dir> <run-id>
hwfi show    <workspace-dir> <run-id>          # pretty-print trace
```

- `hwfi check` performs parse + type-check only, exits non-zero on any
  error.
- Structured inputs: `--input k=v` sets a string; `--input k=@file.json`
  reads a JSON value from `file.json` and binds it at `k`; `--input-json
  <file>` supplies the whole inputs record. Multiple `--input` flags
  compose; `--input-json` is applied first and individual `--input`
  entries override.
- `--entry <qname>` overrides `project.json`'s `entrypoint` for this run.
- `--env-file <path>` supplies provider API keys; takes precedence over
  `<project>/.env` and the process environment (§7.2).

### 9.1 Error message format

All parse and type errors are formatted as:

```
<relative-path>:<line>:<col>: <message>
  |
N | <source line>
  |     ^^^^
```

so output is copy-pasteable into editor jump-to-location. Runtime errors
include the same `qname`/`step_id` used in the trace and, where
available, the source location of the step block.

## 10. Dependencies and tooling

- GHC2021.
- Cabal project. `llm-simple` referenced as a local `packages:` entry
  pointing at `../llm-simple` via `cabal.project`.
- Test framework: `hspec`.
- Markdown parser: `commonmark-hs`.
- Other libraries expected: `aeson`, `text`, `bytestring`, `containers`,
  `filepath`, `directory`, `unliftio`, `megaparsec` (for the step DSL and
  `TypeExpr`), `optparse-applicative`, `ulid` or `uuid`, `cryptonite` or
  `hashable` for step-key hashing, `dotenv` (used directly via
  `Configuration.Dotenv.parseFile`, see §7.2), `typed-process` (for
  `builtin/exec`, §6.3), and `Glob`/`regex` support for `find-files`/`grep`
  (§6.2; the pure matcher may be ported from `llm-simple`'s `LLM.Tools.*`).
- `llm-simple` API surface consumed by `hwfi`: `LLM.Generate` (all
  generation entry points), `LLM.Providers.*` (individual gateway
  constructors), `LLM.Load.ModelCatalog` (catalog parser). `hwfi` does
  **not** use `LLM.Load.loadGateways` or the `*OrThrow` model loaders;
  see §7.2 for why.

## 11. Acceptance criteria (v1)

A1. `hwfi check` on a well-formed project exits 0 and prints nothing on
    stderr.
A2. `hwfi check` on a project with an undeclared reference, type
    mismatch, or import cycle exits non-zero with a message in
    `file:line:col:` format (§9.1).
A3. `hwfi run` on a two-step sample workflow
    (`read-file` → `llm-generate`) produces the expected output file in
    the workspace and a populated `.hwfi/runs/<id>/` directory.
A4. Killing the process mid-run and invoking `hwfi resume` completes the
    run without re-executing already-persisted cacheable steps (verified
    by a step that writes a marker file and would double-write on
    re-execution).
A5. Attempting to write to a path outside the workspace fails with a
    clear error and is recorded in the trace.
A6. A workflow can call another workflow as a step; type-checking
    enforces the callee's signature.
A7. A step whose args reference `${ctx.trace}` is re-executed on resume;
    a cacheable step that does not is skipped (emitting no new trace
    events on the resumed attempt).
A8. `Secret<String>` values loaded from `ctx.env` never appear in
    `trace.jsonl` in cleartext; they render as `<secret:$name>`.
A9. `@self#heading` in a step arg resolves to the current file's markdown
    content under that heading; mismatched slug fails at `hwfi check`.
A10. A shared type alias declared under `types/` and referenced from a
    workflow signature is resolved during type-checking; a cyclic alias
    is rejected at `hwfi check`.
A11. An unknown model name passed to `builtin/llm-generate` fails with an
    error that lists the available model names from the catalog.
A12. A project whose `model-catalog.json` references provider `openai`
    but for which no `OPENAI_API_KEY` is discoverable via `--env-file`,
    `<project>/.env`, or the process environment fails at `hwfi run`
    startup with a message naming the offending model and provider.
A13. Editing a called tool or sub-workflow between an aborted run and
    `hwfi resume` causes every dependent cached step to be recomputed
    (its `callee-fingerprint`, hence `step-key`, changed — §8.1).
A14. A whitelisted `env` variable that is absent from the environment at
    `hwfi run` startup aborts the run before any step executes, with a
    message naming the variable (§5.7).
A15. A downstream step's `ctx.trace` contains the same detailed events
    for an upstream step regardless of whether that upstream step was
    freshly executed or served from cache on resume (§8.3.5).
A16. `builtin/llm-chat` conducts a multi-turn exchange from a `messages`
    history and returns assistant text.
A17. `builtin/llm-agent` runs a multi-round loop in which the model calls an
    advertised `ToolRef`/`WorkflowRef`, receives that callee's typed result
    as a tool message, and then produces a final answer; the callee's
    nested `step-start`/`step-end` events appear between the corresponding
    `agent-tool-call` and `agent-tool-result` (§6.1, §8.3.3.7).
A18. Passing a callee whose declared inputs include a `Secret<_>`,
    `ToolRef`/`WorkflowRef`, or `Bytes` — or a callee that transitively
    calls `builtin/introspect` — in the `tools` argument fails at
    `hwfi check` (§6.1.1, §6.1.5).
A19. `builtin/llm-agent-object` returns the typed record decoded from a
    terminating `submit` call; a `submit` decode failure is fed back to the
    model as a tool message rather than aborting the run, and finishing
    without calling `submit` aborts with an `llm` error (§6.1.3).
A20. Killing the process mid agent-loop and invoking `hwfi resume` completes
    the loop reusing cached model calls and tool-call results — no
    provider calls are re-paid and no tool side effects are re-run (verified
    by an advertised tool that writes a marker file and would double-write
    on re-execution) (§8.2.1).
A21. A tool name the model emits that resolves to no advertised ref, and
    malformed tool arguments, are fed back as recoverable tool messages and
    the loop continues; reaching `max_rounds` without termination aborts
    with an `Error` of kind `llm` (§6.1.4).
A22. The filesystem-mutation builtins (§6.2) confine writes to the
    workspace: `edit-file`/`move-file`/`copy-file`/`remove-file`/`make-dir`/
    `remove-dir` targeting a path outside the workspace fail with a
    `sandbox` error recorded in the trace (as A5 for `write-file`).
A23. `builtin/edit-file` with an `expect` count that does not match the
    actual number of `find` occurrences fails the step with an `eval` error
    and does not modify the file (§6.2).
A24. `builtin/exec` is rejected at `hwfi check` when `program` is absent
    from `project.json.exec.allow` (or no `exec` policy is declared);
    an allowlisted program runs in the workspace and a non-zero exit is
    returned as `exit_code` rather than aborting the run (§6.3, §7.5).
A25. Killing the process mid-run and invoking `hwfi resume` does not
    re-apply a cached mutating step (`edit-file`/`move-file`/…/`exec`) and
    does not re-run a cached `exec` command — its recorded output is
    replayed (§8.2 durable-workspace invariant, §8.2.1).
A26. An agent (`builtin/llm-agent`) advertised the mutation and `exec`
    tools can edit a source file and run an allowlisted build/test command,
    reacting to a non-zero `exit_code` in a subsequent round (§6.1, §6.2,
    §6.3).

## 12. Edge cases and known tricky bits

- Non-UTF-8 files in the workspace: v1 treats `read-file` as text and
  errors on invalid UTF-8. Byte-oriented read deferred to v1.1 via
  `Bytes` type (already reserved in §5.1).
- Very large LLM outputs: step results are written to disk, not held in
  RAM beyond the current step's needs.
- Renaming a workflow file mid-project changes qualified names and
  invalidates cached step keys — acceptable, documented.
- Concurrent runs sharing a workspace: v1 requires an exclusive lock file
  under `.hwfi/`; second `run` fails fast.
- Circular tool imports: rejected at type-check.
- Trace growth over long runs: `trace.jsonl` is append-only text; v1
  imposes no size cap. Rotation deferred to v1.1.

## 13. Explicitly deferred to v1.1+

- Dynamic workflow synthesis by agents. The type checker is already
  factored as a pure function (§5.6) so it can be re-invoked at runtime
  on a freshly-parsed workflow; what remains is a built-in tool along the
  lines of `builtin/eval-workflow(source: String, inputs: Json)
  -> { outputs: Json }` that parses, type-checks, and runs a workflow
  produced by another step. (Note: **LLM tool-use** — a model calling the
  project's *existing* declarations in a loop — is a distinct, weaker
  capability and is **no longer deferred**: it is specified in §6.1 as
  `builtin/llm-agent` / `builtin/llm-agent-object`.)
- OS-level command-execution isolation (namespaces/seccomp/cgroups) for
  `builtin/exec`. (Note: a **filesystem-mutation and command-execution
  toolset** — `edit-file`/`move-file`/…/`exec` gated by an allowlist — is
  **no longer deferred**: it is specified in §6.2/§6.3/§7.5. What remains
  deferred is only stronger per-process containment beyond the allowlist +
  empty-environment model.)
- Cross-run trace reading (reading prior runs' `trace.jsonl`).
- Skill extraction from traces.
- `Bytes`-typed file I/O.
- `trace.jsonl` rotation.
- `Optional<T>` / nullable types (v1 uses strict env presence, §5.7).
- Control-flow-driven error handling (`try`/recover); the engine aborts on
  the first error. The one exception is the agent loop's **localized**
  recoverable-error boundary (§6.1.4), which turns a bad tool call into a
  tool message the model can retry; it does not expose a general
  `try`/recover construct to workflows.

## 14. Known implementation gaps (2026-07-08)

Code review ([code-issues.md](code-issues.md)) found gaps between this spec
and the current engine. Backlog: [TASKS.md](TASKS.md) → **H1**. Normative
requirements are already stated in the sections cited below; this table tracks
what remains to implement.

| ID | Spec | Gap | Fix |
|----|------|-----|-----|
| H1.1 | §7.6 | ~~`hwfi` executable and test suite are built without `-threaded`~~ **done** (2026-07-08). | — |
| H1.2 | §7.1, §6.2 | Workspace guard is lexical only; `read-file` / mutation builtins follow symlinks and can escape the root. Module comment overstates the guarantee. | After lexical resolve, `canonicalizePath` and verify prefix ⊆ workspace root; regression test with `ln -s`. |
| H1.3 | §8.1, §7.3 | One-shot `builtin/llm-*` step-keys omit the model-catalog fingerprint; editing `model-catalog.json` does not invalidate cached LLM results on resume (agent path is correct). | Fold `modelCatalogFingerprint` into `stepKeyFor` for LLM builtins. |
| H1.4 | §4.1 | `runWorkflow` resets scope to `""` at sub-workflow entry; two `par` iterations with identical args share internal step caches. | Thread caller `scope` into `runWorkflow` / `dispatchResolved`. |
| H1.5 | §8.2, §8.3.2 | Unexpected exceptions bypass `finish`; no `run-end`, `run.json.status` stays `running`. | `withException` / `onException` around run body → `error` + `run-end` (`crashed`) + `PhaseCrashed`. |

**Deferred hardening** (spec silent or acceptable for v1; track in TASKS if
needed): O(n²) `ctx.trace` rebuild per step (§8.3.5, perf); O(n²)
`find-files`/`grep` walk; `read-file-slice` re-reads whole file per page
(§6.2, bounded by read cap).
