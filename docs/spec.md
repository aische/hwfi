# Specification

Concrete requirements derived from [idea.md](idea.md). This spec pins v1 scope.
Anything marked **[deferred v1.1]** is intentionally out of scope for v1.

Known gaps between this spec and the current engine are listed in §14 (with
matching backlog items in [TASKS.md](TASKS.md) → v1.1).

## 1. Product summary

A command-line workflow engine, written in Haskell (GHC2021), that:

1. Loads a workflow project consisting of markdown files and a few JSON files.
2. Parses and **type-checks** the entire project before executing anything.
3. Executes the workflow, with access to a designated workspace folder
   (read/create/modify files) and to LLMs via the `llm-simple` library from
   Hackage.
4. Persists execution state and a full trace so runs are **resumable** after
   crash or abort.
5. Exposes the run's environment (workspace, prior trace, inputs) to every
   step via a typed ambient `Context`, so agent steps can inspect what
   happened before them.
6. Is designed so that agent steps can synthesize new workflows at runtime,
   type-check them against the same checker used at load time, and execute
   them via `builtin/eval-workflow` (§6.4). Reading prior runs' traces,
   extracting reusable skills, and **discovering/loading skills at agent
   runtime** are specified and implemented in §6.5–§6.7 (Mode B
   `extract-skill` optional — §6.6.3).

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
skills/                     # optional: reusable agent skills (§6.6–§6.7)
  <name>.md                 # callable declarations and/or instruction guides
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
<bind> <- if <cond> { ... } else { ... } @<id>   -- conditional (§4.1)
<bind> <- foreach v in <list> { ... } @<id>      -- sequential loop (§4.1)
<bind> <- par(max = N) v in <list> { ... } @<id> -- parallel loop (§4.1)
<bind> <- while( predicate = ..., ... ) @<id>    -- predicate/body loop (§4.3)
<bind> <- try { ... } catch { ... } @<id>         -- error recovery (§4.4)
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
Statement       = ReturnStmt | StepStmt | IfStmt | LoopStmt | WhileStmt | TryStmt ;
StepStmt        = Binder "<-" QName "(" ArgList? ")" StepId? ;
IfStmt          = Binder "<-" "if" Expr Block ("else" Block)? StepId? ;
LoopStmt        = Binder "<-" LoopKind Ident "in" Expr Block StepId? ;
LoopKind        = "foreach" | ParKw ;
ParKw           = "par" ("(" ParOpt ("," ParOpt)* ")")? ;
ParOpt          = "max" "=" NumberLit | "on_error" "=" StringLit ;
WhileStmt       = Binder "<-" "while" "(" WhileArgList ")" StepId? ;
TryStmt         = Binder "<-" "try" Block "catch" Block StepId? ;
WhileArgList    = WhileArg ("," WhileArg)* ","? ;
WhileArg        = Ident "=" Expr ;
Block           = "{" Sep? Statement (Sep+ Statement)* Sep? "}" ;
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
  `null`, `_`, `if`, `else`, `foreach`, `par`, `while`, `try`, `catch`,
  `in`, `max`, `on_error`,
  `predicate`, `predicate_args`, `body`, `body_args`, `max_iterations`,
  `carry`.
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

- Sequential steps, plus `if`/`else`, `foreach`, `par` (implemented in M8;
  see §4.1), `while` (§4.3; milestone M9), and `try`/`catch` (§4.4;
  implemented v1.1 task 9.9).
- See §4.2 for scoping rules shared by all control-flow constructs.
- Errors abort the workflow unless caught by `try` (§4.4); the failing step is
  recorded and the run is resumable from that step.

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
  and by default aborts on the **lowest-index** failure (`on_error = "fail"`,
  §4.1.1). The trace writer serialises `emit` so `seq` numbering and on-disk
  line order stay consistent under concurrency.
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
  (`foreach`/`par`/`while`); `if-branch` records the taken arm; `try-branch`
  records the taken `try`/`catch` arm (§4.4.7); `while-pred` records each
  predicate decision (§4.3.6).

#### 4.1.1 `par` error policy (v1.1)

**Status: implemented (v1.1, task 9.9).**

Optional `on_error` in `par(...)` controls iteration failure behaviour:

```
xs <- par(max = N, on_error = "fail") v in ${list} { … } @id    -- default
xs <- par(max = N, on_error = "collect") v in ${list} { … } @id
```

| Mode | Behaviour | Result type |
|------|-----------|-------------|
| `"fail"` (default) | Abort at lowest-index failure; sibling partial results are discarded from the construct value (current §4.1 behaviour). | `List<U>` |
| `"collect"` | Run all iterations; failures become per-index error values. | `List<Record<{ ok: Bool, value: U, error: String }>>` |

For `"collect"`:

- On success at index `i`: `{ ok = true, value = <body result>, error = "" }`.
- On catchable runtime failure at index `i` (same classes as §4.4.4):
  `{ ok = false, value = <unspecified>, error = <message> }`. Workflows must
  guard on `ok` before reading `value`. (A future `Optional<T>` may give `value`
  a proper absent case; §13.)
- Failed iterations are **not cached**; on resume, only failed indices
  re-execute. Completed iterations remain cached under `P/loop#i/` scopes
  (§8.2).
- `loop-end` `count` is the number of iterations **started**, not the
  success count.

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

### 4.3 `while` — predicate/body workflow loop

**Status: implemented (milestone M9).**

`while` is a **value-producing** control-flow construct that repeatedly
invokes two declared workflows — a **predicate** `p` and a **body** `b` — until
`p` reports that iteration should stop, or a static iteration cap is reached.
Unlike `foreach`/`par`, the iteration count is **not known upfront**; unlike
`builtin/llm-agent` (§6.1), orchestration stays at **workflow step
granularity**: each predicate and body invocation is an ordinary nested
sub-workflow call with its own trace, cache keys, and resume behaviour.

Use `while` when discrete, cacheable workflow steps per round matter (e.g.
`workflows/check` → `workflows/fix`). Use `builtin/llm-agent` when the model
should freely choose tools within a round.

#### 4.3.1 Syntax

Callee form (predicate and body are sub-workflows):

```
<bind> <- while(
  predicate = <callee>,
  predicate_args = { <field> = <expr>, ... },
  body = <callee>,
  body_args = { <field> = <expr>, ... },
  max_iterations = <expr>
) @<id>
```

Inline body form (predicate stays a callee; body is a statement block like
`foreach`):

```
<bind> <- while(
  predicate = <callee>,
  predicate_args = { <field> = <expr>, ... },
  body = {
    <statement>*
  },
  max_iterations = <expr>
) @<id>
```

- `<callee>` is a static qname (`workflows/check`) or a `${ref}` where `ref`
  has type `WorkflowRef<In, Out>` in the enclosing binding environment
  (§5.1).
- `predicate_args` is **required**; use `{}` when the predicate takes no inputs.
- In the callee form, `body_args` is **required** (use `{}` when the body
  callee takes no inputs). In the inline form, `body_args` must be omitted.
- `max_iterations` is a required `Int` expression (static literal or binding);
  it must evaluate to a value `≥ 1` at runtime. Reaching the cap without
  `continue = false` aborts the run with an `Error` of kind `user`
  (§8.3.2).
- `_ <- while(...) @id` discards the accumulated body results (side-effect-only
  loop).
- The construct requires an explicit `@id` when the binder is `_` (§3.1).

Example (callee body):

```step
results <- while(
  predicate = workflows/check_done,
  predicate_args = { target = ${inputs.target} },
  body = workflows/refine,
  body_args = { target = ${inputs.target} },
  max_iterations = 20
) @refine_loop
return { iterations = ${results} }
```

Example (inline body):

```step
results <- while(
  predicate = workflows/check_done,
  predicate_args = { target = ${inputs.target} },
  body = {
    r <- workflows/refine(target = ${inputs.target}) @round
  },
  max_iterations = 20
) @refine_loop
return { iterations = ${results} }
```

#### 4.3.2 Predicate contract

The predicate workflow's declared `outputs` must be a record that **structurally
includes** at least:

```
Record<{ continue: Bool, reason: String, ... }>
```

- `continue : Bool` — when `true`, the engine runs one body iteration (if the
  cap allows) and then re-evaluates the predicate; when `false`, the `while`
  terminates successfully.
- `reason : String` — human-readable explanation of the decision, persisted in
  the trace (§4.3.6) for debugging and agent introspection. Not interpreted by
  the engine beyond logging.

Extra output fields are permitted and are ignored by the loop machinery.

The predicate may be any workflow — including one that calls `builtin/llm-agent`,
reads the workspace, or runs `builtin/exec`. There is no restriction that `p`
must be deterministic; resume semantics for non-deterministic predicates are in
§4.3.5.

#### 4.3.3 Body contract and loop value

The body workflow is invoked once per iteration for which the predicate returned
`continue = true`. Its declared `outputs` type is `U`.

- When the `while` binds a name (`xs <- while(...) @id`), the construct's value
  is `List<U>` — the list of body results in iteration order (map semantics,
  same as `foreach`).
- When the binder is `_`, no value constraint is imposed on the body beyond
  ordinary workflow return rules.

#### 4.3.4 Iteration state and `carry`

Sub-workflows do not inherit the parent's binding environment (§5.3); they
receive only their declared `inputs`. State between iterations therefore flows
through:

1. **Workspace mutations** (primary v1 pattern). The body mutates files; the
   predicate inspects them on the next round.
2. **Re-evaluated args.** `predicate_args` and `body_args` are evaluated in the
   **enclosing workflow's** binding environment immediately before each
   invocation, so they may reference bindings from earlier steps in the same
   workflow body.
3. **`carry` — the previous body result.** After iteration `i ≥ 0` completes,
   the body’s return value is available as `${carry}` in `predicate_args`,
   `body_args`, and (for inline bodies) inside the body block for iteration
   `i + 1` only. `${carry}` is **not in scope** for iteration `0`; referencing
   it there is a static type-check error. The type of `carry` is the body
   output type `U` (§4.3.3).

There is no implicit threading of predicate outputs into body inputs; wire
explicit fields in `body_args` if needed.

#### 4.3.5 Execution semantics

For a `while` with static id `w` at scope prefix `P` (§4.1):

```
i ← 0
emit loop-start (kind = "while", no count yet)
while true:
  emit loop-iter (i)
  evaluate predicate_args (carry in scope iff i > 0)
  run predicate at scope P <> w <> "#" <> i <> "/p/"
  extract continue, reason from predicate outputs
  emit while-pred (i, continue, reason)
  pin predicate decision for resume (below)
  if not continue: break
  if i >= max_iterations: abort (kind user)
  evaluate body_args (carry in scope iff i > 0)
  run body at scope P <> w <> "#" <> i <> "/b/
    -- inline body: run statements in iteration scope with carry bound when i > 0
  bind carry ← body result for next iteration
  i ← i + 1
emit loop-end (final count = i)
```

- Predicate and body invocations are **sequential**; there is no `par` variant
  of `while`.
- Errors in either callee abort the enclosing run (§4), same as a failed step
  call.
- Each nested step inside `p` or `b` uses the call-site scope prefix
  (`P/w#i/p/` or `P/w#i/b/`) so per-iteration resume matches `foreach`
  (§4.1).

**Resume and predicate decision pinning.** A completed iteration's predicate
decision must replay identically on resume even when the predicate sub-workflow
is non-cacheable as a whole (e.g. it contains `builtin/llm-agent`, §8.1).

After predicate `i` completes, the engine persists
`{ continue, reason }` under a **decision key**:

```
decision-key(i) = hash( qname, P <> w, "while-pred", i )
```

On resume, if `decision-key(i)` exists, the predicate sub-workflow for
iteration `i` is **not** re-invoked; the stored `continue`/`reason` are used
and a `while-pred` event is not re-emitted (same “no duplicate events on cache
hit” rule as §8.2). If the key is absent, the predicate runs normally.

Body invocations use ordinary sub-workflow / step caching under scope
`P/w#i/b/`. A partially completed body resumes from the first uncached step
inside it.

**Durable-workspace invariant** (§8.2) applies unchanged: a completed body
iteration's mutating steps are not re-applied on resume.

#### 4.3.6 Trace

`while` reuses the loop bracket events from §4.1 with `kind = "while"`:

- `loop-start` — emitted once on entry. Unlike `foreach`/`par`, **`count` is
  omitted** (iteration total unknown).
- `loop-iter` — emitted at the start of each iteration (0-based index).
- `loop-end` — emitted on normal exit with `count` set to the **number of
  predicate evaluations** performed (including the evaluation that returned
  `continue = false`). On abort by `max_iterations`, `count` is the number of
  predicate evaluations before the abort (the cap violation is detected after
  a `continue = true` result).

Additionally, each predicate evaluation emits:

```
| WhilePred {
    tag       : "while-pred",
    seq, at, qname, step_id,    -- enclosing workflow + while @id
    iteration : Int,            -- 0-based
    continue  : Bool,
    reason    : String
  }
```

On resume, pinned decisions do not re-emit `while-pred` (§4.3.5).

#### 4.3.7 Type-checking

In addition to §5.6:

1. `predicate` and `body` must resolve to executable workflows (or
   `WorkflowRef` values whose output types are known).
2. `predicate_args` / `body_args` must match the corresponding callee's
   `inputs` record.
3. The predicate's `outputs` must include `continue: Bool` and
   `reason: String` (structural check).
4. `${carry}` may appear only in `predicate_args` / `body_args` of a `while`, or
   inside an inline body block; its type is the body's output type. It is an
   error to reference `carry` from any other position.
5. `max_iterations` must have type `Int`.
6. When the `while` binds a value, the body's output type must be known and
   the construct's result type is `List<that type>`. For inline bodies, the
   body block must end in a value-producing statement (same rule as `foreach`).
7. `predicate` is always a direct callee for import-graph and Merkle
   fingerprint purposes (§8.1). `body` is either a direct callee (with
   `body_args`) or an inline block whose nested calls contribute to the
   fingerprint like other control-flow blocks.
8. Static import cycles through `while` callees are rejected (§5.6.6). Runtime
   unbounded recursion is bounded by `max_iterations`.
9. Inline `while` bodies must not include `body_args`; callee bodies must
   include `body_args` (use `{}` when empty).

#### 4.3.8 Relation to `builtin/llm-agent`

| Concern | `while(p, b)` | `builtin/llm-agent` |
|---------|---------------|------------------------|
| Who decides to continue? | Predicate workflow (may contain an agent) | Model each round |
| Granularity | One trace step per workflow invocation | One trace step for the whole loop |
| Per-round caching | Sub-workflow step keys + decision pinning | Intra-step model/tool sub-keys (§8.2.1) |
| Typed loop output | `List<U>` from body declarations | `{ text, rounds }` or `{ value, rounds }` |
| Best for | Scripted rounds with optional agent in `p` or `b` | Model-driven tool choice within a round |

A predicate workflow that *is* an `llm-agent` step returning
`{ continue, reason }` via a `submit` schema is valid; decision pinning
(§4.3.5) makes resume deterministic.

### 4.4 `try` / recover

**Status: implemented (v1.1, task 9.9).**

`try` adds an optional, typed catch boundary at workflow step granularity,
with the same scoping, tracing, and resume rules as other control-flow
constructs (§4.1).

`try` is **not** a substitute for:

- branching on `builtin/exec` exit codes (§6.3),
- `{ ok, error }` recoverable builtins (§6.8),
- agent-local recoverable tool errors (§6.1.4),
- `eval-workflow` static failures (§6.4.3).

#### 4.4.1 Syntax

```
<bind> <- try {
  <statement>*
} catch {
  <statement>*
} @<id>
```

- Both arms are brace-delimited statement blocks (same as `if` / `foreach`
  bodies).
- The construct requires an explicit `@id` when the binder is `_` (§3.1).
- `_ <- try { … } catch { … } @id` discards the result (side-effect-only).
- Recovery is always a block; there is no expression-only `catch`.

Example:

```step
r <- try {
  x <- workflows/deploy(version = ${inputs.version}) @deploy
} catch {
  x <- workflows/rollback(version = ${inputs.prev}) @rollback
} @safe_deploy
return { ok = ${r.ok} }
```

#### 4.4.2 Typing

In addition to §5.6:

1. Both arms must end in a **value-producing statement** (same rule as
   `foreach`; no nested `return`).
2. When the construct binds a name, both arms must have **structurally equal**
   result types `U`; the construct's type is `U`.
3. When the binder is `_`, no value constraint is imposed beyond ordinary
   workflow rules in each arm.
4. Bindings in the `try` arm do not escape the `catch` arm and vice versa;
   only the construct's own binder is visible outside.
5. Nested callees in either arm contribute to import-graph and Merkle
   fingerprint purposes like other control-flow blocks (§8.1).

#### 4.4.3 Catchable failures

A `try` catches **runtime errors** from steps and sub-workflow calls
executed inside the `try` arm:

| Error kind | Caught? |
|------------|---------|
| `eval` | yes |
| `user` | yes |
| `io` / `exec` / provider failures surfaced as runtime errors | yes |
| `internal` | **no** — propagates and aborts the run (§8.2) |

Static type-check errors are not catchable (the workflow never runs).

There is **no binding** for the caught error in v1; the `catch` arm runs
with the enclosing environment only. (A future extension may expose
`${error}`; deferred.)

#### 4.4.4 Execution semantics

For a `try` with static id `t` at scope prefix `P` (§4.1):

```
emit try-branch (arm = "try")
run try arm at scope P <> t <> "?try/"
on success:
  value ← try arm result
  goto done
on catchable runtime error:
  emit error (§4.4.7)
  emit try-branch (arm = "catch")
  run catch arm at scope P <> t <> "?catch/"
  value ← catch arm result
done:
  bind construct result
```

- Errors in the **`catch` arm** are **not** caught by the enclosing `try`;
  they abort the workflow normally (§4).
- Side effects in the `try` arm before the failing step **are retained**
  (durable-workspace posture, §8.2). `try` does not roll back workspace
  mutations.
- The failing step emits an `error` trace event and **does not** emit
  `step-end` (unchanged from §8.3).

#### 4.4.5 Caching and step-keys

- Steps in the **try arm** use scope prefix `P/t?try/` (parallel to
  `if?then/`).
- Steps in the **catch arm** use scope prefix `P/t?catch/`.
- A **failed step is never cached** (no persisted result under its step-key;
  §8.2).
- Completed inner steps in either arm are cached normally under their scoped
  step-keys.
- The `try` construct itself is not a separate cacheable step; only its
  inner steps are keyed.

#### 4.4.6 Resume (normative)

| Prior attempt state | On resume |
|---------------------|-----------|
| Try arm in progress, catch not started | Re-run try arm from first uncached step |
| Try arm failed, catch not started | Re-run try arm (failure is not cached) |
| Catch arm in progress | Continue catch arm from first uncached step |
| Construct completed | Skip (cached inner steps; no re-entry) |

Completed steps in either arm are skipped via cache (no duplicate events,
§8.2). Resume never skips directly to `catch` without re-running the try
arm when catch did not complete in the prior attempt.

#### 4.4.7 Trace

| Event | When |
|-------|------|
| `try-branch` `{ branch: "try" \| "catch" }` | Once when entering each arm |
| `error` | When a catchable error occurs in the try arm (before catch runs) |
| `step-start` / `step-end` | Unchanged for inner steps that complete normally |

On resume, cached inner steps emit no new events (§8.2).

#### 4.4.8 Acceptance scenarios (implementation tests)

- **T1:** Try succeeds → catch never runs; result from try arm.
- **T2:** Try step fails → `error` event + catch runs; result from catch arm.
- **T3:** Catch fails → run aborts (not caught by same `try`).
- **T4:** Try partial mutation + failure → catch runs; workspace retains
  try-arm effects.
- **T5:** Resume after try failure before catch → re-runs try, not catch.
- **T6:** Resume mid-catch → continues catch only.
- **T7:** Resume after full success → no re-execution.

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
   over dynamically synthesized workflows (`builtin/eval-workflow`, §6.4).
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
10. `while` (§4.3): `predicate` and `body` callees, `predicate_args` /
    `body_args`, `max_iterations`, predicate output shape, and `${carry}`
    scoping rules are checked as specified in §4.3.7.
11. `try` (§4.4): both arms value-producing with equal tail types; nested
    `return` rejected; catch arm errors not caught by the same construct.
12. `par(on_error = …)` (§4.1.1): `on_error` must be `"fail"` or
    `"collect"`; `"collect"` changes the loop result type to the per-index
    envelope record (§4.1.1).

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
- `builtin/eval-workflow` :
  `{ source: String, inputs: Json }
   -> { ok: Bool, outputs: Json, errors: List<String> }` — parse,
  type-check, and run a workflow definition produced at runtime (§6.4).
- `builtin/json-get` :
  `{ json: Json, path: String }
   -> { ok: Bool, value: Json, error: String }` — dot-separated object-key
  lookup (e.g. `"user.name"`). Missing keys or non-object traversal return
  `ok = false` with an `error` message; does not abort the enclosing run.
- `builtin/json-values` :
  `{ json: Json, path: String }
   -> { ok: Bool, values: List<Json>, error: String }` — collect the values
  of a JSON object or array into a typed list for `foreach`. An empty `path`
  uses `json` as the target; otherwise the path is resolved like `json-get`.
  Object keys are sorted numerically when every key parses as an integer
  (e.g. planner task slots `"0"`, `"1"`, …), otherwise lexicographically.
  JSON `null` entries are omitted. Missing paths or non-object/array targets
  return `ok = false` without aborting the run.
- `builtin/concat` :
  `{ parts: List<String> } -> { text: String }` — concatenate strings in
  order.
- `builtin/record-merge` :
  `{ base: Record, overlay: Record } -> { record: Record }` — merge two
  records; fields present in both must have structurally equal types; overlay
  wins on duplicate keys. Cacheable (§8.1).
- `builtin/record-filter` :
  `{ items: List<Record>, field: String, equals: T } -> { items: List<Record> }`
  — keep records whose named field equals `equals` (static `field` literal
  required for typed `equals`). Cacheable.
- `builtin/record-map` :
  `{ items: List<Record>, field: String } -> { values: List<T> }` — collect
  one field from each record (static `field` literal required for typed
  output). Cacheable.
- `builtin/log` :
  `{ message: String, fields: Json } -> { logged: Bool }` — emit a
  `workflow-log` trace event (§8.3.2) with secrets in `fields` redacted
  (§8.3.4). Non-cacheable (§8.1).
- `builtin/discover-skills` :
  `{ query: String, kinds: List<String>, limit: Int }
   -> { ok: Bool, skills: List<SkillEntry>, error: String }` — list
  skills from the project catalog whose metadata matches the filter (§6.7.1).
  Read-only, cacheable. Agent-eligible.
- `builtin/load-skill` :
  `{ id: String }
   -> { ok: Bool, kind: String, loaded: Bool, content: String, error: String }`
  — load one skill by qname (§6.7.2). When called **inside** an agent loop,
  mutates that step's active context (callable tools and/or instruction
  text). When called from a scripted step, returns metadata only (no agent
  mutation). Non-cacheable. Agent-eligible.

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
4. The result `RValue` is consumed in three ways:
   - **Tool message to the model** — redacted JSON (§8.3.4), including on
     resume when served from the intra-step cache (`toolModelJson`).
   - **Intra-step tool cache** (`steps/*.json`) — actual non-redacted JSON
     (`valueToJson`), so resume can reconstruct the typed value and re-apply
     redaction for the model without re-running the callee (§8.2.1).
   - **Trace** (`agent-tool-result`, nested `step-end`) — redacted JSON as
     persisted (§8.3.4). Scripted (non-agent) steps cache the actual `RValue`
     at the step level instead (§8.1).

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
  itself surfaces as an error, `submit` decode failures, and
  `builtin/eval-workflow` returning `ok = false` (parse/type-check failure
  on synthesized source — §6.4).
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

#### 6.1.6 Dynamic tools and skill loading

**Status: implemented (2026-07-09, task 9.15).**

The `tools` argument on `builtin/llm-agent` / `builtin/llm-agent-object`
may be a **list literal** of bare tool/workflow names or any expression of
type `List<ToolRef<_, _> | WorkflowRef<_, _>>` (§6.1.6 phase 2). Agents
may also **discover and load** skills mid-loop via §6.7 (Cursor-style
progressive disclosure).

**Baseline tool set.** Every agent that uses dynamic skills must advertise
`builtin/discover-skills` and `builtin/load-skill` in its `tools` list
(alongside domain builtins such as `builtin/read-file`). There is no
implicit injection — authors include the meta-tools explicitly, or via a
shared prompt fragment.

**Runtime `tools` list (phase 2).** The checker is relaxed so `tools` may
be any expression of type `List<ToolRef<_, _> | WorkflowRef<_, _>>`, not
only a list literal. A scripted step may assemble the initial toolbox from
prior `discover-skills` / `load-skill` results before calling
`builtin/llm-agent`. Eligibility rules (§6.1.1, §6.1.5) still apply to
every ref in the list at check time when the list is statically known; for
fully dynamic lists the checker validates only that the expression's type is
correct and emits a warning if refs cannot be resolved statically.

**Mid-loop expansion (phase 3).** When the model calls `builtin/load-skill`
inside an agent step:

- **`kind = "callable"`** — if the skill resolves to an agent-eligible
  declaration that passed `hwfi check`, it is added to the **active tool
  set** for subsequent rounds. The provider receives updated tool
  definitions on the next model call.
- **`kind = "instruction"`** — the skill body (markdown after frontmatter)
  is appended to the agent's **instruction context** (see §6.7.2). This
  does not add a callable tool.

Loading the same `id` twice is idempotent: `loaded = false` with a tool
message explaining it is already active.

**Recoverable failures** for `load-skill`: unknown `id`, skill failed
`hwfi check`, ineligible callable (§6.1.1), instruction over token budget,
or load cap exceeded (§6.7.3).

**Caching and resume (§8.2.1).** The agent checkpoint records, per round:

- `active-tool-ids` — ordered list of callable skill qnames loaded so far
  (plus the baseline `tools` from the step arguments).
- `loaded-instruction-ids` — instruction skills merged into context.

The `advertised-tools-fingerprint` for model-call sub-keys incorporates
`active-tool-ids` at the **start of each round**, so a cache hit only
occurs when the same tools were active when that round was first executed.
Instruction loads affect `messages-so-far` directly and therefore the
model-call sub-key without a separate fingerprint field.

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

### 6.4 Dynamic workflow evaluation (`builtin/eval-workflow`)

**Status: implemented (task 9.2).**

`builtin/eval-workflow` lets an agent (or any step) parse, type-check, and
run a workflow definition produced at runtime — e.g. markdown the model
wrote in an earlier round. This is distinct from `builtin/llm-agent`
(§6.1), which calls *existing* project declarations; `eval-workflow`
executes *new* source text against the same checker and executor used at
load time.

#### 6.4.1 Signature and result shape

```
builtin/eval-workflow :
  { source: String, inputs: Json }
  -> { ok: Bool, outputs: Json, errors: List<String> }
```

- `source` — the full text of a single workflow markdown file (same format
  as a file under `workflows/`, §2).
- `inputs` — root inputs for the dynamic workflow, coerced against its
  declared input record (same rules as `hwfi run` root inputs, §9).
- `ok` — whether parse, type-check, and execution all succeeded.
- `outputs` — on success, the dynamic workflow's output record as `Json`;
  on failure before or during a successful run boundary, `{}`.
- `errors` — on failure, one or more human-readable diagnostic strings in
  the §9.1 format (`file:line:col: message` with optional caret block);
  on success, `[]`.

The step **always completes normally** (emits `step-end`) when the only
failure is parse or type-check. It does **not** abort the enclosing run for
bad synthesized source — callers (including agents) inspect `ok` and
`errors` and decide what to do next.

#### 6.4.2 Pipeline

1. **Parse** `source` as one workflow declaration. A parse failure sets
   `ok = false`, populates `errors`, and stops — the workflow body is never
   executed.
2. **Merge** the parsed declaration into a *synthetic project* consisting
   of all declarations from the enclosing run's checked project plus the
   dynamic workflow. The dynamic declaration is assigned a fixed virtual
   path `<eval-workflow>` for diagnostics (§9.1). Name collisions with an
   existing declaration are type-check errors.
3. **Type-check** the synthetic project with the same pure checker as
   `hwfi check` (§5.6.8). Any `[TypeError]` sets `ok = false`, renders
   each error to §9.1 form in `errors`, and stops — the body is never
   executed.
4. **Coerce** `inputs` against the dynamic workflow's declared inputs. A
   coercion failure sets `ok = false` with an `errors` entry and stops.
5. **Execute** the dynamic workflow as a nested run through the normal
   executor (same workspace, sandbox, trace nesting, and step-key rules as
   a sub-workflow call). On success, set `ok = true` and `outputs` to the
   result record.

The dynamic workflow may call any tool or sub-workflow declared in the
parent project (subject to the usual static call-graph and eligibility
rules). It does not gain access to declarations that were not part of the
loaded project.

#### 6.4.3 Error posture

| Failure | Step result | Enclosing run |
|---------|-------------|---------------|
| Parse error on `source` | `ok = false`, `errors` populated | Continues |
| Type-check error on synthetic project | `ok = false`, `errors` populated | Continues |
| `inputs` coercion failure | `ok = false`, `errors` populated | Continues |
| Runtime error during execution of a checked workflow | — | Aborts (§4) |

Rationale: synthesized source is expected to be wrong sometimes (the
primary use case is agent-generated workflows). Aborting the whole run on
the first type error would prevent the model from reading diagnostics and
retrying. Once source passes the checker, failures are ordinary workflow
errors.

When `eval-workflow` is advertised as an agent tool (§6.1), a result with
`ok = false` is fed back to the model as a normal tool message (the
serialised `{ ok, outputs, errors }` record). The agent loop continues;
this is a **recoverable** outcome (§6.1.4), not a fatal `Error` event on
the agent step.

Scripted callers branch on `${result.ok}` (or equivalent), or use `try`/`catch`
once implemented (§4.4).

#### 6.4.4 Caching and fingerprinting

- The step is **non-cacheable** (§8.1): `source` is typically unique per
  invocation.
- Built-in fingerprint follows the engine-version rule for `builtin/*`
  (§8.1).
- Steps *inside* a successfully checked dynamic workflow use normal
  step-key and cache semantics, scoped under the eval-workflow call site
  (§4.1).

#### 6.4.5 Agent eligibility

`eval-workflow` is **agent-eligible** (§6.1.1): its inputs are `String`
and `Json` only. Projects typically expose it to agents via a thin tool
wrapper or by including a `ToolRef` to such a wrapper in the agent's
`tools` list.

### 6.5 Cross-run trace reading

**Status: implemented (2026-07-09, task 9.3).**

Today `ctx.trace` and `builtin/introspect` expose only the **current**
logical run, up to the executing step (§5.2, §8.3.5). Cross-run reading
lets workflows and agents inspect **prior** runs persisted under
`<workspace>/.hwfi/runs/` (§8.2).

#### 6.5.1 Builtins

```
builtin/list-runs :
  { limit: Int }
  -> { runs: List<Record<{
       id: String,
       started_at: String,
       entrypoint: String,
       status: String
     }>> }

builtin/read-run-trace :
  { run_id: String }
  -> { ok: Bool, events: List<TraceEvent>, error: String }
```

- `limit` — maximum number of runs to return, most recent first. Must be
  `>= 1`; values above `100` are clamped to `100`.
- `run_id` — the id of a run directory under `<workspace>/.hwfi/runs/`.
  The special value `"current"` is equivalent to `ctx.run.id`.
- `events` — parsed `trace.jsonl` lines in file order, same ADT as
  `ctx.trace` (§8.3). Secrets remain redacted as persisted.
- `ok = false` when the run directory is missing or `trace.jsonl` cannot be
  read; `events` is `[]` and `error` is human-readable. Does **not** abort
  the enclosing run (same recoverable posture as §6.4.3).
- Malformed lines in `trace.jsonl` are skipped (same rules as resume,
  §8.3.5).

Neither builtin reads outside the current workspace's `.hwfi/runs/` tree.
There is no cross-workspace or cross-project trace access in v1.1.

#### 6.5.2 Caching and agent eligibility

- Both steps are **non-cacheable** (§8.1): the set of runs grows over time
  and authors expect fresh listings.
- Both are **agent-eligible** (§6.1.1): plain scalars and structured outputs
  only; they do not call `builtin/introspect`.
- Referencing `${ctx.trace}` and calling these builtins in the same step is
  allowed; the step remains non-cacheable.

#### 6.5.3 Trace events

Each builtin emits a `file-io` trace event with op `"list"` (for
`list-runs`, path `.hwfi/runs`) or op `"read"` (for `read-run-trace`, path
`.hwfi/runs/<run_id>/trace.jsonl`). No new `TraceEvent` variants in v1.1.

### 6.6 Skills (declarations and extraction)

**Status: extraction implemented (2026-07-09, tasks 9.4.1–9.4.3). Mode B
(`extract-skill`) optional / not implemented (A40). Runtime
discovery/loading implemented in §6.7 (task 9.15).**

A **skill** is a markdown file under `skills/` registered in the project
catalog. Skills are not a separate AST node: they use the same parser,
checker, and executor as `tools/` and `workflows/`. Two **kinds** are
supported (§6.6.1):

- **`callable`** — a full tool or workflow declaration (default). The
  engine treats `skills/fix-import` like `tools/fix-import` once
  `hwfi check` passes.
- **`instruction`** — prose guidance only (no executable steps). Loaded
  into the agent's instruction context at runtime (§6.7.2), not into the
  call graph.

Rationale: reuse static typing and Merkle fingerprints for callable skills;
avoid forcing every reusable pattern into a typed declaration when prose
suffices (Cursor-style progressive disclosure).

#### 6.6.1 Skill kinds and file layout

Skills live under `skills/<name>.md`. The `skill:` frontmatter block
carries catalog metadata; remaining fields are convention / future lint.

**Callable skill** (default — backward compatible with existing projects):

```yaml
---
name: skills/fix-import
skill:
  kind: callable
  summary: "Repair a missing import after a cabal build failure"
  tags: ["cabal", "haskell"]
  source_run: "<run-id>"
  source_qname: "workflows/fix"
  source_step_id: "agent"
  extracted_at: "2026-07-09T12:00:00.000Z"
---
```

Omitting `kind` defaults to `callable`. The file body is a normal tool or
workflow declaration (§2).

**Instruction skill**:

```yaml
---
name: skills/shell-repair-guide
skill:
  kind: instruction
  summary: "Procedure for fixing sh syntax errors with sh -n"
  tags: ["shell", "syntax"]
---
# Shell repair guide

1. Run `sh -n <file>` before editing.
2. Read the file; make the smallest fix.
3. Re-run `sh -n` until exit 0.
```

Instruction skills **must not** contain executable `step` blocks. The
checker rejects `kind: instruction` files that parse as tool/workflow
declarations with steps. Authors may include markdown sections (`## agent`,
etc.) as documentation only.

**Promotion paths** (how a skill becomes available to an agent):

| Path | Callable | Instruction |
|------|----------|-------------|
| Explicit | `imports:` or `tools = [skills/foo, …]` on `llm-agent` | Concatenate body into `system` before the agent step |
| Dynamic | `builtin/load-skill` inside an agent loop (§6.7.2) | Same |

There is no automatic registration at project load: even callable skills
must be **loaded** (dynamically or listed in `tools`) before the model can
invoke them.

#### 6.6.2 Trace slice (deterministic extraction input)

Before synthesizing markdown, extraction needs a **bounded trace slice** —
the events belonging to one logical step in a prior run:

```
builtin/trace-slice :
  { run_id: String,
    qname: String,
    step_id: String,
    include_nested: Bool
  }
  -> { ok: Bool, events: List<TraceEvent>, error: String }
```

- Resolves `run_id` like §6.5.1 (`"current"` allowed).
- Returns events whose `(qname, step_id)` match the filter, in trace order.
- When `include_nested = true`, also includes events from sub-workflow and
  agent-internal calls **scoped under** that step (same nesting rules as
  `hwfi show` indentation: agent `agent-*` events share the agent step's
  `qname`/`step_id`; nested sub-workflow calls carry their own pair but
  occur between the enclosing step's `step-start` and `step-end`).
- When `include_nested = false`, only events with exactly the given pair.
- Missing run → `ok = false` (recoverable). Empty slice → `ok = true`,
  `events = []`.

`trace-slice` is **non-cacheable** and **agent-eligible**.

Typical slices for skill extraction:

| Goal | `include_nested` | Tags of interest |
|------|------------------|------------------|
| Agent procedure replay | `true` | `agent-tool-call`, `agent-tool-result`, `file-io`, `exec` |
| Scripted sub-workflow | `false` | `step-start`, `step-end`, `file-io` |
| Predicate decision pattern | `false` | `while-pred`, `llm-call` |

#### 6.6.3 Extraction modes

**Mode A — agent-driven (recommended first implementation).**

No dedicated "write skill file" builtin is required. A workflow:

1. Calls `builtin/trace-slice` (and optionally `builtin/read-run-trace`) on
   a successful prior run.
2. Passes the slice (as JSON via `${events}` interpolation or a follow-up
   `llm-gen-object` step) to a model with a fixed schema for tool/workflow
   markdown.
3. Writes the result with `builtin/write-file` to `skills/<name>.md`.
4. Optionally calls `builtin/eval-workflow` to smoke-test the synthesized
   source before committing (§6.4).

The author runs `hwfi check` on the project (or a CI step) before the skill
is callable on the next run. This matches the existing eval-workflow +
workspace mutation pattern from `examples/coding`.

**Mode B — `builtin/extract-skill` (optional convenience).**

```
builtin/extract-skill :
  { run_id: String,
    qname: String,
    step_id: String,
    target: String,
    kind: String,
    include_nested: Bool
  }
  -> { ok: Bool, path: String, source: String, errors: List<String> }
```

- `target` — workspace-relative path, must start with `skills/` and end
  with `.md` (e.g. `skills/fix-import.md`). Rejects overwrite unless
  `project.json` sets `"skills": { "allow_overwrite": true }` (default
  `false`).
- `kind` — `"tool"` or `"workflow"`; selects which declaration shape the
  engine emits in v1.1.
- On success, writes `source` to `path` under the workspace (same sandbox
  as other mutation builtins), sets `ok = true`, and returns the written
  text in `source`.
- v1.1 **deterministic** body: serialize the trace slice to a comment block
  and emit a **stub** declaration whose steps are `builtin/introspect`-free
  placeholders (e.g. a tool whose prompt embeds the slice summary and
  instructs the model to follow the recorded tool-call sequence). **LLM
  summarization inside this builtin is deferred** — Mode A covers that.

`extract-skill` is non-cacheable. It is agent-eligible if the checker is
extended to treat `kind` as an enum literal (v1.1: accept only the two
strings above at runtime with a recoverable `ok = false` on unknown
`kind`).

#### 6.6.4 Project manifest

Optional `project.json` stanza:

```json
{
  "skills": {
    "allow_overwrite": false,
    "directory": "skills"
  }
}
```

- `directory` — reserved for Mode B writes (default `"skills"`). The
  project parser currently walks the fixed top-level `skills/` directory;
  a non-default `directory` is parsed but not yet honored by the loader
  (§14).
- `allow_overwrite` — safety gate for Mode B (§6.6.3); unused until
  `extract-skill` is implemented.

The project loader walks `skills/` alongside `tools/`, `workflows/`, and
`types/` (task 9.4.1). Callable **tool** skills and `kind: instruction`
files are registered in the runtime catalog (§6.7); callable **workflow**
declarations under `skills/` are loaded for `hwfi check` but are not
catalog entries for `discover-skills` / `load-skill` today.

#### 6.6.5 Security and secrets

- Cross-run traces are already redacted at write time (§5.5, §8.3.4).
- Skills must not embed raw secret values from traces; the checker already
  forbids promoting `Secret<T>` into plain strings (§5.5).
- Agent-eligible skills must satisfy §6.1.1 (no `introspect`, no secret
  inputs). An extracted stub that calls `builtin/introspect` fails
  `hwfi check` when promoted to an agent tool — by design.

#### 6.6.6 Implementation order (extraction)

1. **9.3** — `list-runs`, `read-run-trace`, RunStore helpers, tests A36–A37.
2. **9.4.1** — load `skills/` declarations in the project parser/checker.
3. **9.4.2** — `trace-slice`, tests A38–A39.
4. **9.4.3** — example `examples/skills` agent-driven extraction workflow
   (Mode A); optional `extract-skill` (Mode B) and A40.

Runtime discovery and loading: §6.7 (**done**, task 9.15).

Extended rationale and example flows: [skills-design.md](skills-design.md).

### 6.7 Agent skill catalog and loading

**Status: implemented (2026-07-09, task 9.15).**

Agents discover skills from a **catalog** built at `hwfi check` time from
every `skills/*.md` file's frontmatter plus type-check status. They load
skills mid-loop via `builtin/load-skill` (§6.1.6). This is the Cursor-style
**progressive disclosure** model: the model sees summaries first, then pulls
full callable tools or instruction text only when needed.

#### 6.7.1 Skill catalog and `builtin/discover-skills`

At check time the engine builds an in-memory **skill catalog** from the
project:

| Field | Source |
|-------|--------|
| `id` | Frontmatter `name` (qualified, e.g. `skills/fix-shell`) |
| `kind` | `skill.kind`, default `callable` |
| `summary` | `skill.summary`, or first non-empty line of body if absent |
| `tags` | `skill.tags`, default `[]` |
| `path` | Project-relative file path |
| `checked` | Whether the declaration passed `hwfi check` (`callable` only) |
| `agent_eligible` | Whether a callable skill may be advertised as an agent tool (§6.1.1, §6.1.5) |

```
builtin/discover-skills :
  { query: String,
    kinds: List<String>,
    limit: Int
  }
  -> { ok: Bool, skills: List<SkillEntry>, error: String }
```

`SkillEntry` is a record:

```
{ id: String, kind: String, summary: String, tags: List<String>,
  checked: Bool, agent_eligible: Bool }
```

Behaviour:

- `query` — case-insensitive substring match against `id`, `summary`, and
  `tags`. Empty `query` returns all skills (subject to `kinds` and `limit`).
- `kinds` — filter by skill kind. Empty list means no kind filter. Unknown
  kind strings in the filter are ignored. Valid kinds: `"callable"`,
  `"instruction"`.
- `limit` — maximum entries returned, most relevant first. Relevance order:
  tag match, then summary match, then id match. Must be ≥ 1; default 20 at
  the builtin boundary if authors pass `0`.
- Read-only: scans the checked project's catalog only (not arbitrary
  workspace paths). **Cacheable** (§8.1).
- Emits a `skill-discover` trace event (§8.3.2) with `query`, `kinds`,
  `limit`, and result count (no full skill bodies).

When called from inside an agent loop, results are returned to the model as
a normal tool message. The model is expected to call `discover-skills`
before `load-skill` when the catalog is unknown.

#### 6.7.2 `builtin/load-skill`

```
builtin/load-skill :
  { id: String }
  -> { ok: Bool, kind: String, loaded: Bool, content: String, error: String }
```

- `id` — skill qname (e.g. `skills/fix-shell`). Must exist in the catalog.
- On success: `ok = true`, `kind` echoes the skill kind, `loaded = true` on
  first load in the current agent step, `loaded = false` if already active.
- **`callable` + inside agent loop:** adds the skill to `active-tool-ids`
  (§6.1.6) if `checked` and `agent_eligible`. `content` is empty. The callee
  is advertised on the **next** model round.
- **`callable` + scripted step:** does not mutate any agent. Returns
  `{ ok = true, loaded = false, content = "" }` — use explicit `tools`
  lists or call from within an agent instead.
- **`instruction` + inside agent loop:** appends the markdown body (after
  frontmatter) to the agent instruction context. The engine inserts a
  synthetic system message of the form:

  ```
  ## Loaded skill: <id>

  <body>
  ```

  before the next model round. `content` echoes the inserted text (for
  scripted callers). Instruction skills do not require `hwfi check` beyond
  frontmatter validation.
- **`instruction` + scripted step:** returns the body in `content` without
  agent mutation; callers may concatenate into `system` manually.
- Recoverable failures (`ok = false`): unknown `id`, callable not checked,
  callable not agent-eligible, instruction body exceeds
  `skills.max_instruction_chars` (§6.7.3), or load cap exceeded.
- **Non-cacheable** (§8.1). Emits a `skill-load` trace event with `id`,
  `kind`, and `loaded`.

#### 6.7.3 Limits and project manifest

Extend the optional `project.json` `skills` stanza (§6.6.4):

```json
{
  "skills": {
    "directory": "skills",
    "allow_overwrite": false,
    "max_callable_loads": 8,
    "max_instruction_loads": 5,
    "max_instruction_chars": 12000
  }
}
```

| Field | Default | Notes |
|-------|---------|-------|
| `max_callable_loads` | `8` | Per agent step; baseline `tools` do not count |
| `max_instruction_loads` | `5` | Per agent step |
| `max_instruction_chars` | `12000` | Total instruction body chars across all loaded instruction skills in one agent step |

#### 6.7.4 Recommended agent workflow

```step
result <- builtin/llm-agent(
  system = @self#agent,
  prompt = "...",
  model = "smart",
  tools = [
    builtin/discover-skills,
    builtin/load-skill,
    builtin/read-file,
    builtin/edit-file,
    builtin/exec
  ],
  max_rounds = 16
)
```

The model discovers relevant skills, loads them, then uses newly advertised
callable skills or follows loaded instructions. Authors keep a small
**baseline** toolbox (filesystem, exec, meta-tools); domain skills stay in
`skills/` until loaded.

#### 6.7.5 Security

- Callable skills loaded at runtime must have passed `hwfi check` and satisfy
  §6.1.1 / §6.1.5 — same rules as statically listed tools.
- Instruction skills are prose only; they cannot execute code. The checker
  rejects instruction files with executable steps (§6.6.1).
- `discover-skills` never returns full skill bodies — only metadata — so
  large instruction files are not dumped into context until explicitly
  loaded.
- Instruction content is subject to the same redaction rules as system
  prompts if it interpolates secrets (authors should not embed secrets in
  skills).

#### 6.7.6 Implementation order

Delivered (task 9.15, 2026-07-09):

1. **9.15.1** — Skill catalog at check time; `kind` frontmatter; instruction
   vs callable validation; `discover-skills` builtin; tests A45–A46.
2. **9.15.2** — `load-skill` for instruction skills (context injection);
   scripted-step behaviour; `skill-discover` / `skill-load` trace events;
   tests A47.
3. **9.15.3** — `load-skill` for callable skills (mid-loop tool expansion);
   agent checkpoint fields; `advertised-tools-fingerprint` per round;
   tests A48–A49.
4. **9.15.4** — Runtime `List<Ref>` expressions for `tools` (§6.1.6
   phase 2); example `examples/skills-runtime`; test A50.

### 6.8 Data plumbing and workflow logging

**Status: implemented (R1, tasks 9.5 subset).**

The builtins `builtin/json-get`, `builtin/json-values`, `builtin/concat`, and
`builtin/log` are listed in the §6 builtin table above. They reduce friction
when shaping data between steps without giant string interpolations or ad-hoc
LLM calls.

- `json-get`, `json-values`, and `concat` are **cacheable** (§8.1).
- `log` is **non-cacheable**: authors expect a fresh `workflow-log` line when
  the step re-executes on resume.

Further record operations remain in the backlog (§13.1.2).

Record builtins `record-merge`, `record-filter`, and `record-map` are
**implemented** (v1.1, task 9.10). The checker infers merged/filtered/mapped
types from the argument record shapes when `field` is a string literal.

### 6.8.1 Counted loop sugar (`range`)

**Status: implemented (v1.1, task 9.11 subset).**

The expression `range(n)` evaluates to `List<Int>` containing `[0, …, n-1]`
when `n : Int` and `n ≥ 0`; negative counts are a runtime `eval` error. It
may appear anywhere a `List<Int>` is expected, e.g. `foreach i in range(3) {
… }`.

### 6.8.2 Inline `while` bodies

**Status: implemented (v1.1, task 9.11).**

`while` may use either a callee body (`body = workflows/…`, `body_args = {…}`)
or an inline statement block (`body = { … }` without `body_args`). The
predicate remains a callee in both forms. Inline bodies follow the same
value-producing rules as `foreach` (last step binding, no nested `return`).
`${carry}` is in scope inside the block from the second iteration onward
(§4.3.4, §4.3.7).

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
4. `$XDG_CONFIG_HOME/hwfi/.env`, if the file exists (user-level fallback).

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
`hwfi resume` after a catalog change. `pricing` changes do not rewrite
historical `llm-call` events; they affect only new live calls (§8.4).

Provider–key linking is validated at startup: for every model referenced
in the catalog, the corresponding provider key must be available from
the sources in §7.2 (except `ollama`, which requires no key). Missing
keys fail startup with:

```
error: model 'gpt_4_1' in model-catalog.json requires provider 'openai',
  but OPENAI_API_KEY was not found in --env-file, <project>/.env, the
  process environment, or $XDG_CONFIG_HOME/hwfi/.env.
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
machine.json      # v2 machine snapshot (cursor + frames); see execution-model.md
trace.jsonl       # append-only event log
```

The v2 runtime (M6+) does **not** persist `steps/<step-key>.json` cache files.
Resume loads `machine.json` and continues via `stepMachine` (§8.2).

Author-facing guide: [caching-and-resume.md](caching-and-resume.md).

### 8.1 Step-key hashing

Step-keys and Merkle fingerprints remain part of **static classification** at
check time (`classifyCacheable`, callee invalidation, §5.6). They are emitted
on trace events for observability but are **not** used to skip execution on
resume in the v2 runtime.

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

The following builtins are also **always non-cacheable** regardless of
arguments: `builtin/eval-workflow`, `builtin/list-runs`,
`builtin/read-run-trace`, `builtin/trace-slice`, `builtin/log`
(§6.5, §6.8), `builtin/load-skill` (§6.7).

An agent step (`builtin/llm-agent` / `builtin/llm-agent-object`, §6.1) is
**also non-cacheable as a whole**: its behaviour — which tools it calls, in
what order, with what arguments — is chosen by the model and is not a
function of its resolved arguments, so it cannot be a cacheable black box.
`classifyCacheable` treats it like `builtin/introspect`. Its *internal*
units are cached instead (§8.2.1).

### 8.2 Resume semantics

Author-facing guide: [caching-and-resume.md](caching-and-resume.md).

- **Machine snapshot.** After each completed transition (and on step-batch
  pause), the runtime writes `machine.json` — cursor (`StmtPath`), frames,
  bindings, `current` (agent / `par` / confirm), and status. `hwfi continue`
  / `hwfi step` reload this snapshot and call `stepMachine` until the
  requested stop condition.
- **Project staleness.** Continue is refused when `project_hash` in `run.json`
  differs from the current project directory hash; start a new run id.
- **No step-key skip.** Completed work is represented in the snapshot; there
  is no lookup of `steps/<step-key>.json` on resume (M6).
- A transition is atomic: partial LLM output is not resumed mid-call unless
  the agent snapshot says otherwise (§8.2.1).
- On resume the runtime appends one `Resumed` marker (§8.3.2) before any
  new events, then continues numbering `seq` from the last value + 1.
- A run is resumable if `run.json.status ∈ {running, crashed, aborted}`.
- **Crash handling.** Typed `RuntimeError` values end a run deliberately
  (`run-end` with `status: aborted`, `run.json.status: aborted`). An
  **unexpected synchronous exception** must emit a terminal `error` event
  (`kind: internal`), append `run-end` with `status: crashed`, set
  `run.json.status` to `crashed`, then exit. `crashed` runs remain resumable
  like `aborted` ones.

**Durable-workspace invariant.** Resume treats the workspace directory as
**durable state carried over from the interrupted attempt**. Transitions
already completed before the snapshot was written are not re-applied; a
transition interrupted mid-flight is re-run from the snapshot. If the workspace
is mutated out-of-band between attempts, reads may no longer match reality —
the snapshot does not encode live file contents.

**`while` predicate pinning (§4.3.5).** Predicate `continue`/`reason` for
iteration `i` is recorded as a `while-pred` trace event (with `decision_key`).
On resume, if that decision is already present, the predicate sub-workflow for
iteration `i` is not re-invoked and the event is not re-emitted.

### 8.2.1 Agent loop resume (v2)

An agent step is non-cacheable as a whole (§8.1). In the v2 runtime, resume
does **not** replay model/tool sub-keys from `steps/`. Instead, `machine.json`
stores `CurAgent` state (round index, messages, pending tool calls, etc.) and
`stepMachine` continues the loop from that snapshot. Mid-round resume re-runs
the interrupted transition if it had not completed.

Legacy v1 intra-step sub-key caching (`steps/*.json`) is removed (M6).

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
      tokens_out : Int,
      cost_usd   : Double         -- this call only (§8.4)
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
  | IfBranch {
      tag     : "if-branch",
      seq, at, qname, step_id,
      branch  : "then" | "else" | "none"
    }
  | TryBranch {
      tag     : "try-branch",
      seq, at, qname, step_id,
      branch  : "try" | "catch"
    }
  | LoopStart {
      tag     : "loop-start",
      seq, at, qname, step_id,
      kind    : "foreach" | "par" | "while",
      count   : Int?              -- present for foreach/par; omitted for while
    }
  | LoopIter {
      tag       : "loop-iter",
      seq, at, qname, step_id,
      iteration : Int             -- 0-based
    }
  | LoopEnd {
      tag   : "loop-end",
      seq, at, qname, step_id,
      count : Int                 -- iteration count (see §4.1, §4.3.6)
    }
  | WhilePred {
      tag       : "while-pred",
      seq, at, qname, step_id,
      iteration : Int,
      continue  : Bool,
      reason    : String
    }
  | WorkflowLog {
      tag     : "workflow-log",
      seq, at, qname, step_id,
      message : String,
      fields  : Json              -- secrets redacted (§8.3.4)
    }
  | SkillDiscover {
      tag    : "skill-discover",
      seq, at, qname, step_id,
      query  : String,
      kinds  : List<String>,
      limit  : Int,
      count  : Int                 -- entries returned
    }
  | SkillLoad {
      tag    : "skill-load",
      seq, at, qname, step_id,
      id     : String,
      kind   : String,
      loaded : Bool
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
code; parse/type-check failures on dynamic source are returned as
`eval-workflow`'s `ok = false` result instead — §6.4), `eval` (expression
evaluation failure — list index out of bounds,
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
   call_index)`. A `builtin/log` step emits `workflow-log` between its
   `StepStart` and terminal. Each round's model generation appears as an
   `LlmCall`
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

### 8.4 Usage and cost accounting

**Status: implemented (R1, task 9.8).** v1 records per-call token counts and
`cost_usd` on `llm-call` trace events (§8.3.2), maintains a running total in
`run.json` and `ctx.run.usage`, and supports an optional `project.json`
budget ceiling.

#### 8.4.1 Scope

- **In scope:** LLM provider spend only (`builtin/llm-*` and agent model
  rounds). File I/O, `exec`, and CPU time are not costed.
- **Unit:** United States dollars (`cost_usd : Double`). Display may round
  to cents; persistence uses full precision.
- **Logical run:** one `run id` across all resume attempts (§8.3.3). The
  running total is monotonic for the logical run and survives `Resumed`
  markers.

#### 8.4.2 What counts as spend

A cost increment is recorded **only when the engine makes a live provider
call** and receives a response (including a provider error that still
returned usage metadata).

The following are **free** — they add `0` to the running total and emit
**no** new `llm-call` event (consistent with §8.3.3.7):

- A cacheable step served from the step cache on resume.
- An agent model round served from an intra-step model sub-cache (§8.2.1).
- An agent tool call served from an intra-step tool sub-cache (§8.2.1).
- Replaying a prior attempt's cached units during a resume re-walk.

Summing `cost_usd` over all `llm-call` events in `trace.jsonl` must equal
the final `run.json` total for the logical run. Nested agents (an outer
agent calling a workflow/tool that runs an inner agent) share one run-scoped
accumulator; depth does not double-count.

#### 8.4.3 Cost per call

When a live provider call completes, the engine computes `cost_usd` for
that call:

1. If the provider response includes a non-zero `usageTotalCost` (from
   `llm-simple`'s `Usage`), use it.
2. Otherwise estimate from the resolved catalog entry's `pricing` and the
   reported `tokens_in` / `tokens_out`:
   `(tokens_in × pricePerMillionInput + tokens_out × pricePerMillionOutput) / 1_000_000`.

The `model` field on the event is the catalog `modelConfigName`, so
retrospective repricing after a catalog edit does not rewrite persisted
events; totals are fixed at call time.

#### 8.4.4 Running total — where it lives

The engine maintains a **run-scoped running total**, updated atomically
after each billed provider call (at the same sites that emit `llm-call`:
one-shot builtins and agent model rounds, including nested agents):

**`run.json`** — extended with a `usage` object, rewritten after each
billed call and on terminal phases:

```json
"usage": {
  "tokens_in": 12450,
  "tokens_out": 890,
  "cost_usd": 0.0234
}
```

**`ctx.run.usage`** — the same record, exposed on the ambient `Context`
(§5.2) so workflows can branch on spend (e.g. audit steps, early exit).
Shape when the feature is enabled:

```
run = Record {
  id         : String,
  started_at : String,
  entrypoint : String,
  usage      : Record {
    tokens_in  : Int,
    tokens_out : Int,
    cost_usd   : Double
  }
}
```

`ctx.run.usage` is **volatile** for step-key hashing (§8.1): referencing
it makes the step non-cacheable, same as `ctx.trace`.

#### 8.4.5 Trace extension

Each billed `llm-call` event includes a `cost_usd` field:

```
| LlmCall {
    ...
    tokens_in  : Int,
    tokens_out : Int,
    cost_usd   : Double    -- this call only, not the running total
  }
```

`hwfi show` prints the per-call cost and a summary line after the trace
(e.g. `usage: 12450/890 tokens, $0.02`).

#### 8.4.6 Optional budget

`project.json` may declare an optional spend ceiling:

```json
"budget": {
  "max_cost_usd": 1.0
}
```

When present, the engine checks `ctx.run.usage.cost_usd` **before each
live provider call** at any nesting depth. If the running total is already
≥ `max_cost_usd`, the call is not made and the run aborts with an `Error`
of kind `llm` naming the budget and the current total. Omitted `budget` means
no limit.

Budget checks use the running total after all prior billed calls in the
logical run; cached replays do not consume budget because they are not
provider calls.

#### 8.4.7 Attribution (non-normative)

Per-call `llm-call` rows carry the immediate `(qname, step_id)`. To
attribute spend to an enclosing agent tool call, consumers walk the trace
tree: inner events fall between the matching `agent-tool-call` and
`agent-tool-result` (§8.3.3.6–7). No separate parent pointer is required
for v1.1; a later version may add optional rollup fields on `agent-tool-result`.

## 9. CLI

Binary name: `hwfi`. Minimal v1 surface:

```
hwfi check   <project-dir>
hwfi run     <project-dir> --workspace <dir>
             [--env-file <path>]
             [--input <k>=<v>]... [--input <k>=@<file.json>]...
             [--input-json <file.json>]
             [--entry <qname>]
hwfi resume  <workspace-dir> <run-id>          # alias for continue
hwfi continue <workspace-dir> <run-id>         # resume from machine.json
hwfi step    <workspace-dir> <run-id>          # one transition batch, then pause
hwfi show    <workspace-dir> <run-id>          # pretty-print trace + usage
```

`hwfi show` prints the run's accumulated `usage` (tokens and `cost_usd`) from
`run.json` after the trace. Resume continues from `machine.json` (§8.2); there
is no `steps/` cache or `hwfi cache *` commands in the v2 runtime (M6).
`while-pred` events may carry `decision_key` for predicate pinning (§4.3.5).

- `hwfi check` performs parse + type-check only, exits non-zero on any
  error.
- Structured inputs: `--input k=v` sets a string; `--input k=@file.json`
  reads a JSON value from `file.json` and binds it at `k`; `--input-json
  <file>` supplies the whole inputs record. Multiple `--input` flags
  compose; `--input-json` is applied first and individual `--input`
  entries override.
- `--entry <qname>` overrides `project.json`'s `entrypoint` for this run.
- `--env-file <path>` supplies provider API keys; takes precedence over
  `<project>/.env`, the process environment, and `$XDG_CONFIG_HOME/hwfi/.env`
  (§7.2).

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
- Cabal project. `llm-simple` `^>=0.1.0.1` from Hackage (`build-depends` in
  `hwfi.cabal`).
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
    `<project>/.env`, the process environment, or `$XDG_CONFIG_HOME/hwfi/.env`
    fails at `hwfi run`
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
A30. A `while` loop invokes `predicate` then `body` until `continue` is
    `false`, producing `List<U>` from body outputs; reaching `max_iterations`
    without termination aborts with kind `user` (§4.3).
A31. Killing a run mid-`while` and resuming does not re-apply completed body
    iterations' workspace side effects; predicate decisions are replayed from
    pinned decision keys (§4.3.5, §8.2).
A32. A `while` whose predicate workflow contains `builtin/llm-agent` replays the
    same `continue` decision on resume without re-invoking the predicate (§4.3.5).
A33. `${carry}` in `predicate_args`/`body_args` is rejected at `hwfi check`
    when it would be in scope for iteration 0 (§4.3.4).
A27. A live `builtin/llm-generate` call increments `run.json` `usage.cost_usd`
    and `ctx.run.usage.cost_usd`; a cache hit on resume does not.
A28. An agent model round served from intra-step cache on resume emits no
    new `llm-call` and does not increment the running total.
A29. With `project.json` `budget.max_cost_usd` set, a provider call that
    would exceed the ceiling aborts before the request is sent.
A34. `builtin/eval-workflow` with ill-typed `source` returns
    `{ ok = false, errors = [...] }` and does not abort the enclosing run;
    the workflow body is not executed.
A35. When `eval-workflow` is an agent tool and returns `ok = false`, the
    agent loop continues and the model receives the error diagnostics in
    the tool message (§6.4.3).
A36. `builtin/list-runs` returns prior runs for the current workspace,
    most recent first, without reading outside `.hwfi/runs/`.
A37. `builtin/read-run-trace` with a missing `run_id` returns
    `{ ok = false, error = ... }` and does not abort the enclosing run;
    `"current"` resolves to `ctx.run.id`.
A38. `builtin/trace-slice` with `include_nested = true` on an agent step
    includes `agent-tool-call` / `agent-tool-result` events for that step.
A39. A declaration under `skills/` type-checks and is callable like an
    equivalent `tools/` declaration once loaded (§6.6.1).
A41. `builtin/json-get` returns `{ ok = true, value = ... }` for an
    existing dot-separated path and `{ ok = false, error = ... }` for a
    missing key without aborting the run.
A41a. `builtin/json-values` returns `{ ok = true, values = [...] }` for a
    JSON object or array (after optional path resolution), with object keys
    sorted numerically when all keys are integers, JSON `null` entries omitted,
    and `{ ok = false, error = ... }` for missing paths or non-collection
    targets without aborting the run.
A42. `builtin/concat` joins a list of strings into `text`.
A43. `builtin/log` emits a `workflow-log` trace event with redacted `fields`
    and is re-executed on resume (non-cacheable).
A44. *(removed M6)* — v2 resume uses `machine.json`; no step cache to clear.
A44a. *(removed M6)* — use a new `run-id` to force a full retry.
A45. `builtin/discover-skills` returns catalog metadata for skills under
    `skills/` filtered by `query`, `kinds`, and `limit`; empty catalog
    yields `ok = true` and `skills = []`.
A46. `discover-skills` never includes full instruction bodies — only
    `id`, `kind`, `summary`, `tags`, `checked`, and `agent_eligible`.
A47. `builtin/load-skill` with `kind = instruction` inside an agent loop
    injects the markdown body into the agent context; loading the same
    `id` twice returns `loaded = false` without duplicating context.
A48. `builtin/load-skill` with `kind = callable` inside an agent loop
    adds an agent-eligible checked skill to the active tool set for
    subsequent rounds.
A49. Agent resume replays mid-loop skill loads: checkpoint records
    `active-tool-ids` and `loaded-instruction-ids`; model-call sub-keys
    use the round's `advertised-tools-fingerprint` (§8.2.1).
A50. `builtin/llm-agent` accepts a runtime `List<ToolRef | WorkflowRef>`
    expression for `tools`, not only a list literal (§6.1.6 phase 2).

The following are specified but not yet implemented:

A40. (Mode B only) `builtin/extract-skill` writes under `skills/` and
    refuses overwrite when `allow_overwrite` is false.

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
- `while` with a predicate that reads volatile `ctx` fields: the predicate
  is re-executed on resume unless a decision key already exists (§4.3.5).
  Authors should prefer workspace-backed state for resume-stable loops.

## 13. Explicitly deferred to v1.1+

- OS-level command-execution isolation (namespaces/seccomp/cgroups) for
  `builtin/exec`. (Note: a **filesystem-mutation and command-execution
  toolset** — `edit-file`/`move-file`/…/`exec` gated by an allowlist — is
  **no longer deferred**: it is specified in §6.2/§6.3/§7.5. What remains
  deferred is only stronger per-process containment beyond the allowlist +
  empty-environment model.)
- Cross-run trace reading — §6.5 (**implemented**).
- Skill extraction from traces — §6.6 Mode A (**implemented**); Mode B
  (`builtin/extract-skill`) optional / **not implemented** (A40).
- Agent skill discovery and loading — §6.7 (**implemented**, task 9.15).
- `Bytes`-typed file I/O.
- `trace.jsonl` rotation.
- `Optional<T>` / nullable types (v1 uses strict env presence, §5.7).
- **Author capability backlog (post-v1)** — §13.1 items 9.9–9.14 are
  **implemented**; remaining v1.1 work is listed in [TASKS.md](TASKS.md).

### 13.1 Author capability backlog (post-v1)

Items surfaced by author-facing review (2026-07). Tasks 9.9–9.14 shipped
2026-07-12; open v1.1 items remain in [TASKS.md](TASKS.md).

#### 13.1.1 Control-flow error handling (`try`/recover)

**Priority: 1.** Extend beyond today's partial escape hatches:

- `builtin/exec` already returns non-zero exit as a **value** (§6.3).
- The agent loop has a **localized** recoverable boundary (§6.1.4), including
  `builtin/eval-workflow` returning `ok = false` (§6.4.3).
- Scripted workflows abort on the first uncaught runtime error (§4).

**Implemented (v1.1, task 9.9):**

- **`try` / `catch`** — workflow-level catch boundary with typed arms, scoped
  step-keys, trace events, and resume rules (§4.4).
- **`par(on_error = "collect")`** — opt-in per-index success/failure envelope
  instead of fail-fast (§4.1.1). Default `"fail"` preserves current behaviour.

Not a substitute for `eval-workflow`'s `{ ok, errors }` result shape (§6.4);
that builtin covers recoverable *static* failures on synthesized source.

#### 13.1.2 Data plumbing

**Priority: 2.** Reduce friction when shaping data between steps without
giant string interpolations or ad-hoc LLM calls:

- **Record operations** — `builtin/record-merge`, `record-filter`, and
  `record-map` on typed `Record<{…}>` values. **[implemented, §6.8]**
- **JSON path access** — `builtin/json-get` over `Json` values with dot-separated
  keys and recoverable `{ ok, error }` on missing paths. **[implemented, §6.8]**
- **JSON object/array to list** — `builtin/json-values` collects values into
  `List<Json>` for `foreach`, with numeric key ordering for planner-style slot
  objects. **[implemented, §6.8]**
- **String concatenation** — `builtin/concat` concatenates strings without
  JSON-encoding entire records via interpolation (§3.2.1). **[implemented, §6.8]**

#### 13.1.3 Simpler loop syntax

**Priority: 3.** Control flow exists (§4.2, §4.3) but common patterns are
verbose:

- **Inline `while` bodies** — predicate stays a callee; `body = { … }` runs
  statements in the iteration scope (optional `${carry}` from iteration 1+).
  Callee form unchanged. Inline predicates remain deferred.
  **[implemented, §6.8.2]**
- **Counted loops** — `range(n)` expression sugar for `foreach`/`par`.
  **[implemented, §6.8.1]**

#### 13.1.4 Cache invalidation policy (author-visible)

**Priority: 4.** Automatic invalidation on code edit is already correct:
Merkle `callee-fingerprint` in the step-key (§8.1) changes when any transitive
callee changes, so resume after an edit does not silently reuse stale step
files for changed code.

**Implemented (M6):** Step-key cache and `hwfi cache *` removed. Resume uses
`machine.json`; project-hash staleness replaces Merkle step-file invalidation
for execution. Static fingerprints remain for check-time classification (§8.1).
Author guide: [caching-and-resume.md](caching-and-resume.md).

**Documented policy:**

- Automatic Merkle fingerprint invalidation vs manual busting (workspace edits,
  suffix re-run, full wipe) — see author guide table.

#### 13.1.5 Observability in workflows

**Priority: 5.** `ctx.trace` reconstructs full history (§8.3.5) but is heavy
for authoring and debugging:

- **`builtin/log`** — emits a `workflow-log` trace event (§8.3.2) with
  named fields in `fields` (secrets redacted, §8.3.4). Non-cacheable so
  resume replays log lines. **[implemented, §6.8]**
- Optional stdout mirroring and richer field typing remain deferred.

#### 13.1.6 Dynamic dispatch ergonomics (`WorkflowRef` / `ToolRef`)

**Implemented (2026-07-12, task 9.14).** Author guide:
[workflow-refs.md](workflow-refs.md); checker hints for common ref mistakes;
example [`examples/workflow-refs`](../examples/workflow-refs).

First-class refs (§5.1) and fingerprint-aware step-keys (§8.1) support
dynamic dispatch. Documentation covers:

- Refs passed as inputs, refs collected into lists for `builtin/llm-agent`
  `tools`, and conditional dispatch via `if` on flags (static qnames per
  branch).
- Checker hints for common mistakes (bare qname vs step call, static tools
  list syntax).
- Cross-links from §6.1 (agent tools), §6.4 (`eval-workflow` vs existing
  declarations), and §6.7 (dynamic skill loading).

#### 13.1.7 Agent skill runtime (discover / load)

**Implemented (2026-07-09, task 9.15).** Normative spec: §6.7;
`examples/skills-runtime`. Cursor-style progressive disclosure: agents browse
a skill catalog via `discover-skills`, then load callable tools or
instruction prose via `load-skill`.

**Relationship to §6.6:** extraction (trace → `skills/foo.md`) is the
*authoring* path; §6.7 is the *runtime* path. A distilled callable skill
must still pass `hwfi check` before `load-skill` can advertise it.

**Follow-ups (not blocking):** semantic/embedding discover (substring match
today); `hwfi skill list` CLI; honor `skills.directory` in the project
walker; catalog entries for callable workflow skills under `skills/`.

## 14. Known implementation gaps

**H1 (2026-07-08): complete.** Regression map: [h1-verification.md](h1-verification.md).

| ID | Spec | Status |
|----|------|--------|
| H1.1 | §7.6 | **done** — threaded RTS in `hwfi.cabal` |
| H1.2 | §7.1, §6.2 | **done** — `resolveContainedPath`; `WorkspaceSpec` symlink tests |
| H1.3 | §8.1, §7.3 | **done** — model-catalog fingerprint in one-shot LLM step-keys |
| H1.4 | §4.1 | **done** — sub-workflow scope threading; `ControlFlowSpec` |
| H1.5 | §8.2, §8.3.2 | **done** — `guardedFinish` crash path; `ExecutorSpec` |

**Deferred hardening** (acceptable for v1; track in [TASKS.md](TASKS.md) if
needed): O(n²) `ctx.trace` rebuild per step (§8.3.5, perf); O(n²)
`find-files`/`grep` walk; `read-file-slice` re-reads whole file per page
(§6.2, bounded by read cap).

**Skill runtime polish** (§6.7 implemented; minor spec/code drift):

| Item | Spec / intent | Current engine |
|------|---------------|----------------|
| `skills.directory` | Configurable catalog root | Parsed in `project.json`; walker hardcodes `skills/` |
| Callable workflow skills | `skills/foo.md` as workflow | Loaded by checker; not in discover/load catalog |
| Mode B | `builtin/extract-skill` | Not implemented (A40); `allow_overwrite` unused |
