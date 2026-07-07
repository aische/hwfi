# Specification

Concrete requirements derived from [idea.md](idea.md). This spec pins v1 scope.
Anything marked **[deferred v1.1]** is intentionally out of scope for v1.

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
  "env": []
}
```

`env` is optional (defaults to `[]`); when present, it whitelists process
environment variables that will be readable via `ctx.env` at runtime.
Anything not listed is not visible to the workflow. Provider API keys
(`OPENAI_API_KEY`, `CLAUDE_API_KEY`, `GEMINI_API_KEY`, `DEEPSEEK_API_KEY`)
do **not** need to be in `env`: they are consumed by `hwfi`'s own
gateway loader and never flow through `ctx.env` — see §7.2.

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

**[deferred v1.1]** shell/exec tool.

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
4. The result `RValue` is serialised to JSON as the tool-message content
   for the next round.

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

## 7. Workspace, project, and sandboxing

### 7.1 Filesystem layout at runtime

- Engine receives `--workspace <dir>` on the CLI.
- All `FileRef` values are resolved relative to the workspace root.
- Path traversal outside the workspace is rejected at runtime; the
  workspace root is canonicalised once at start.
- The workspace is the **only** filesystem area the workflow may write to.
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

Network access is available only via `llm-simple` calls invoked by
`builtin/llm-*`; no arbitrary HTTP tool in v1.

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
      op      : "read" | "write" | "list",
      path    : String,            -- workspace-relative
      bytes   : Int                -- payload size; 0 for "list"
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
      status : "completed" | "aborted"
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
   aborted}`). A run interrupted by a crash has no `RunEnd` until a later
   attempt completes or permanently aborts it; resumability is determined
   by `run.json.status`, not by the presence of `RunEnd`.
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
  `Configuration.Dotenv.parseFile`, see §7.2).
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

- Control flow (`if`, `foreach`, `par`).
- Shell/exec tool with sandbox policy.
- Dynamic workflow synthesis by agents. The type checker is already
  factored as a pure function (§5.6) so it can be re-invoked at runtime
  on a freshly-parsed workflow; what remains is a built-in tool along the
  lines of `builtin/eval-workflow(source: String, inputs: Json)
  -> { outputs: Json }` that parses, type-checks, and runs a workflow
  produced by another step. (Note: **LLM tool-use** — a model calling the
  project's *existing* declarations in a loop — is a distinct, weaker
  capability and is **no longer deferred**: it is specified in §6.1 as
  `builtin/llm-agent` / `builtin/llm-agent-object`.)
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
