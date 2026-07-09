# Workflow author reference

This manual is for **workflow authors**: people who write hwfi projects
(markdown workflows, tools, and configuration) and run them with the `hwfi`
CLI. It covers the syntax, types, builtins, and runtime behaviour you need
to design and execute workflows. For normative detail and acceptance criteria,
see [spec.md](spec.md).

**Related guides**

- [caching-and-resume.md](caching-and-resume.md) — step cache, resume, agent replay
- [tool-use.md](tool-use.md) — design rationale for agent tool loops
- Example projects under `examples/` — runnable patterns from minimal to full

---

## What hwfi does

hwfi is a workflow engine that:

1. Loads a **project directory** (markdown + JSON).
2. **Type-checks** the whole project (`hwfi check`) before running anything.
3. Executes the entry workflow in a **sandboxed workspace** with durable traces.
4. Persists every step so runs are **resumable** after crash or abort.

Workflows are **prompt-authored programs**: you declare typed inputs/outputs,
compose steps in a small DSL, and call builtins, sub-workflows, and tools.
LLM calls and agent loops are ordinary steps.

---

## Quick start

```bash
mkdir -p /tmp/hwfi-ws
echo "Article text here." > /tmp/hwfi-ws/article.txt

cabal run hwfi -- check examples/summarise

cabal run hwfi -- run examples/summarise \
  --workspace /tmp/hwfi-ws \
  --input path=article.txt \
  --input out=summary.txt
```

Set `DEEPSEEK_API_KEY` (or the key for your catalog provider) via
`examples/summarise/.env`, `--env-file`, or your shell. See
[Provider keys](#provider-keys-and-env).

On success, the workspace contains `summary.txt` and
`.hwfi/runs/<run-id>/` with trace and cache.

---

## Project layout

A project is a directory:

```
project.json              # manifest: name, entrypoint, env, exec policy
model-catalog.json        # required: LLM model entries (see below)
.env                      # optional: provider API keys
workflows/
  main.md                 # default entry (name must match path)
  <name>.md               # more workflows
tools/
  <name>.md               # reusable step scripts
types/
  <name>.md               # shared type aliases (optional)
skills/
  <name>.md               # agent skills (optional)
```

**Naming.** Each `.md` file is exactly one declaration. Its qualified name
(`qname`) is the path relative to the project root **without extension** —
e.g. `workflows/plan`, `tools/lookup`, `builtin/read-file`. Renaming a file
changes the qname; update all callers.

**`project.json` (minimal)**

```json
{
  "name": "my-project",
  "version": "0.1.0",
  "entrypoint": "workflows/main",
  "env": []
}
```

Optional fields:

| Field | Purpose |
|-------|---------|
| `env` | Whitelist of process env vars exposed as `ctx.env` (strict presence at startup) |
| `exec` | Policy for `builtin/exec` — **absent means exec is disabled** |
| `skills` | Skill catalog limits — see [Skills](#skills) |

Example `exec` block:

```json
"exec": {
  "allow": ["sh", "npm", "node", "cabal"],
  "env": ["PATH", "HOME"],
  "timeout_ms": 120000,
  "max_output_bytes": 1048576
}
```

- `allow` — program **basenames** only (e.g. `"git"`, not `/usr/bin/git`). No wildcards.
- `env` — vars passed to child processes (defaults to empty environment).
- Provider API keys are **not** passed to `exec` unless explicitly listed (discouraged).

---

## Workflows and tools

Workflows and tools share the same syntax. The difference is intent:

- **Workflow** — orchestration: multiple steps, control flow, sub-workflow calls.
- **Tool** — a single-purpose callable unit, often one step, exposed to agents.

Both have YAML frontmatter and a markdown body. The body may contain prose
(documentation, prompts) and fenced **`step`** blocks.

### Frontmatter

```yaml
---
name: workflows/main          # must equal file path (no .md)
inputs:
  path: FileRef
  limit: Int
outputs:
  summary: String
imports:
  - builtin/read-file
  - builtin/llm-generate
  - tools/lookup
---
```

- `inputs` / `outputs` — map of field names to types (see [Types](#types)).
- `imports` — qnames the checker must resolve (transitive closure for fingerprints).

### Minimal workflow

````markdown
---
name: workflows/main
inputs:
  path: FileRef
outputs:
  summary: String
imports:
  - builtin/read-file
  - builtin/llm-generate
---

## system

You are a concise summariser. One paragraph, no preamble.

## flow

```step
contents <- builtin/read-file(path = ${inputs.path})
summary  <- builtin/llm-generate(
  system = @self#system,
  prompt = "Summarise:\n\n${contents.text}",
  model  = "default"
) @summarise
return { summary = ${summary.text} }
```
````

Prose sections (`## system`, `## flow`, `## agent`, …) are documentation for
humans. Only `step` blocks execute. Section text can be referenced in steps
via `@self#<heading-slug>` (see [Prompt sections](#prompt-sections)).

---

## Step DSL

Inside a ` ```step ` fenced block, **one statement per line** (comments with
`--`).

### Step call

```
<bind> <- <qname>(<args>) @<step-id>
```

- `<bind>` — name for the result in later steps, or `_` to discard (then
  `@step-id` is required).
- `<qname>` — tool, workflow, builtin, or a `ToolRef`/`WorkflowRef` in scope.
- `<args>` — `key = expr` pairs, comma-separated; newlines allowed inside `(...)`.
- `@<step-id>` — optional but recommended; used in traces and cache keys.
  Defaults to the bind name when omitted.

### Return

When `outputs` is non-empty, end with an explicit return (unless the last
step's result type exactly matches `outputs` — rare; tool results are usually
shaped like `{ text }` while outputs use different field names):

```step
return { summary = ${summary.text}, count = ${n} }
```

### Execution order

Multiple `step` blocks and prose interleave in source order. Execution follows
**source order** across all step blocks in the file.

### Bind rules

- Bind names must be **unique** in a workflow (no shadowing at workflow level).
- Inside control-flow blocks, scoping is block-local (see [Control flow](#control-flow)).

---

## Expressions

| Form | Example | Notes |
|------|---------|-------|
| String | `"hello"` | Interpolation: `"hello ${name}"` |
| Long string | `"""multi\nline"""` | Interpolation supported |
| Number | `42`, `3.14` | |
| Bool | `true`, `false` | |
| Null | `null` | JSON null |
| List | `[a, b, c]` | |
| Record | `{ k = v, k2 = v2 }` | Values use `=`, not `:` |
| Reference | `${inputs.path}` | Bare `${...}` keeps the value's type |
| Field access | `${result.text}` | |
| Index | `${list[0]}` | Not bounds-checked statically |
| Self section | `@self#system` | String content of heading in current file |
| Bare qname | `builtin/read-file` | Only where `ToolRef` / `WorkflowRef` expected |

**No** arithmetic, conditionals, or lambdas in v1.

### References vs interpolation

- **Bare reference** — `text = ${contents.text}` passes the typed value through.
- **Inside a string** — `"File: ${contents.text}"` renders the value to text and
  splices it. Most types render as JSON; `String` is verbatim.

`Secret<_>` and `Bytes` cannot appear in string interpolation (static error).

---

## Types

### Base types

| Type | Use |
|------|-----|
| `String`, `Int`, `Double`, `Bool` | Primitives |
| `Json` | Opaque JSON value |
| `Bytes` | Opaque bytes |
| `FileRef` | Path relative to workspace |
| `List<T>` | Homogeneous list |
| `Record<{ f: T, ... }>` | Struct — **types use `:`** in frontmatter |
| `WorkflowRef<In, Out>`, `ToolRef<In, Out>` | First-class callable refs (agent `tools` lists; not dynamic step targets — see [Agent steps](#agent-steps)) |
| `Secret<T>` | Redacted in traces; not model-supplied; see [Secrets](#secrets-and-ctxenv) |
| `Context`, `Trace`, `TraceEvent` | Ambient / introspection |

### Type aliases

File under `types/`:

```markdown
---
kind: type-alias
name: types/message
definition: Record<{ role: String, content: String }>
---
```

Reference in signatures as `types/message`.

### Record syntax split

- **Type positions** (YAML): `Record<{ name: String }>` — colon between fields.
- **Value positions** (steps): `{ name = "x" }` — equals between fields.

---

## Prompt sections

Long prompts live in markdown headings instead of giant string literals:

```markdown
## agent

You are a coding agent. Read before you edit.
```

In a step:

```step
result <- builtin/llm-agent(
  system = @self#agent,
  prompt = "Fix ${inputs.target}",
  ...
)
```

Slug rules: heading text → lowercase, non-word runs → `-`, trim edges.
Matching is case-insensitive (`@self#Agent` = `@self#agent`).

---

## Built-in tools

Engine-provided callees at `builtin/<name>`. Import them in `imports:`.

### Filesystem (read)

| Builtin | Inputs → outputs |
|---------|------------------|
| `read-file` | `{ path }` → `{ text }` |
| `read-file-slice` | `{ path, offset, limit }` → `{ text, next_offset, eof }` |
| `list-dir` | `{ path }` → `{ entries }` |
| `find-files` | `{ path, glob }` → `{ paths }` |
| `grep` | `{ pattern, path }` → `{ matches }` |

- **`read-file-slice`** — pages through a file by **line** (0-based `offset`,
  `limit` lines). Returns `next_offset` to continue and `eof` when done. Use
  inside agents for files larger than one tool result.
- **`grep`** — RE2 regex over text files under `path`. Malformed patterns fail
  the step. Each match is `{ file, line, text }`.
- **Text only** — reads of binary files or files over the engine byte cap fail
  with an `io` error.

### Filesystem (mutate)

| Builtin | Inputs → outputs / notes |
|---------|--------------------------|
| `write-file` | `{ path, text }` → `{}` |
| `edit-file` | `{ path, find, replace, expect }` → `{ replacements }` |
| `move-file`, `copy-file` | `{ from, to }` → `{}` |
| `remove-file` | `{ path }` → `{}` |
| `make-dir` | `{ path }` → `{}` |
| `remove-dir` | `{ path }` → `{}` (recursive, workspace-confined) |

- **`edit-file`** — literal (non-regex) whole-string replacement of `find`.
  `expect` is the asserted occurrence count; a mismatch fails the step (no
  silent partial edit). Returns how many replacements were made.

All mutation builtins are cacheable; on resume a cache hit means the effect
is already in the workspace.

### Command execution

`builtin/exec` — `{ program, args, stdin, timeout_ms }` →
`{ exit_code, stdout, stderr, timed_out }`.

- **Argv, not shell** — pass `program = "sh"`, `args = ["-c", "..."]` explicitly.
- **Non-zero exit is a value**, not a run error — workflows and agents can branch on it.
- Disabled unless `project.json` `exec.allow` lists the program basename.

### LLM (workflow-driven)

| Builtin | Purpose |
|---------|---------|
| `llm-generate` | Single-shot text: `{ system, prompt, model }` → `{ text }` |
| `llm-chat` | Multi-turn: `{ system, messages, model }` → `{ text }` |
| `llm-gen-object` | Structured JSON: `{ system, prompt, schema, model }` → `{ value }` |

`model` names a **`modelConfigName`** in `model-catalog.json`, not a raw provider id.

**`llm-chat` messages** — `messages` is a `List<Record<{ role: String, content: String }>>`.
Define a type alias (e.g. `types/message`, `types/chat-log`) and pass it with a
bare reference:

```step
reply <- builtin/llm-chat(
  system   = @self#reviewer,
  messages = ${inputs.history},
  model    = "default"
)
```

**`llm-gen-object` schema** — pass an explicit JSON Schema in `schema`, or
`schema = null` and describe the shape in the prompt (see
[Structured planning](#structured-planning)).

### LLM (model-driven)

| Builtin | Purpose |
|---------|---------|
| `llm-agent` | Tool loop → `{ text, rounds }` |
| `llm-agent-object` | Tool loop + mandatory `submit` → `{ value, rounds }` |

See [Agent steps](#agent-steps).

### Data and logging

| Builtin | Inputs → outputs |
|---------|------------------|
| `json-get` | `{ json, path }` → `{ ok, value, error }` — dot-path lookup (`"tasks.0.title"`) |
| `json-values` | `{ json, path }` → `{ ok, values, error }` — object/array → `List<Json>` |
| `concat` | `{ parts }` → `{ text }` |
| `log` | `{ message, fields }` → `{ logged }` — `workflow-log` trace event (non-cacheable) |

`json-get` and `json-values` return `ok = false` instead of aborting when the path
is missing or invalid. Branch on `ok` in scripted steps; agents see the full
record as a tool result.

### Skills runtime

| Builtin | Inputs → outputs |
|---------|------------------|
| `discover-skills` | `{ query, kinds, limit }` → `{ ok, skills, error }` |
| `load-skill` | `{ id }` → `{ ok, kind, loaded, content, error }` |

- **`discover-skills`** — scans the checked project's skill catalog. `query` is
  a case-insensitive substring match on id, summary, and tags (use short
  keywords). `kinds` filters (`"callable"`, `"instruction"`); empty = all.
  `limit` ≥ 1 (default 20). Each `SkillEntry` has
  `{ id, kind, summary, tags, checked, agent_eligible }`. Cacheable.
- **`load-skill`** — loads a skill by qname (e.g. `skills/fix-shell`). Inside an
  agent: callable skills join the active tool set on the **next** round;
  instruction skills inject prose into context. Outside an agent: instruction
  bodies return in `content` for manual concatenation. Non-cacheable.

See [Skills](#skills) for runtime behaviour and limits.

### Introspection and dynamics

| Builtin | Cacheable? | Purpose |
|---------|------------|---------|
| `introspect` | No | `{ data: Json }` — full current-run dump |
| `eval-workflow` | No | `{ source, inputs }` → `{ ok, outputs, errors }` |
| `list-runs` | No | `{ limit }` → `{ runs }` — recent runs under workspace |
| `read-run-trace` | No | `{ run_id }` → `{ ok, events, error }` |
| `trace-slice` | No | `{ run_id, qname, step_id, include_nested }` → `{ ok, events, error }` |

**`eval-workflow`** — parse, type-check, and run workflow markdown produced at
runtime (e.g. model-written source). Parse/type/coercion failures set
`ok = false` and populate `errors` **without aborting** the enclosing run.
Runtime errors inside a successfully checked dynamic workflow still abort.
Agent-eligible; `ok = false` is recoverable in agent loops.

**Cross-run trace** — reads only `<workspace>/.hwfi/runs/`. `run_id = "current"`
means `ctx.run.id`. Missing runs return `ok = false`, not a run abort.
`trace-slice` filters events for one logical step; `include_nested = true`
includes nested sub-workflow and agent-tool events.

---

## Agent steps

`builtin/llm-agent` and `builtin/llm-agent-object` hand the model a list of
**project tools and workflows**. The model chooses calls in a loop until it
terminates or hits `max_rounds`. Each model-chosen call runs through the normal
executor as a **nested step** (nested trace, sandboxed workspace, content-addressed
cache). The model never touches the filesystem directly.

### Free-text agent (`llm-agent`)

```step
result <- builtin/llm-agent(
  system = @self#agent,
  prompt = "Fix ${inputs.target}",
  model = "smart",
  tools = [
    builtin/read-file,
    builtin/grep,
    builtin/edit-file,
    builtin/exec
  ],
  max_rounds = 12
) @fix
return { answer = ${result.text}, rounds = ${result.rounds} }
```

Terminates when the model answers with **plain text and no tool calls**.
Returns `{ text, rounds }`. `max_rounds` must be ≥ 1; exhaustion without
termination is fatal.

### Typed agent (`llm-agent-object`)

Use when the agent must return **structured JSON** after using tools — the
union of tool-calling and structured output. Instead of provider JSON mode, the
engine synthesizes a terminating **`submit`** tool whose parameters are your
`schema` argument.

```step
result <- builtin/llm-agent-object(
  system = @self#agent,
  prompt = ${inputs.question},
  model = "smart",
  tools = [ tools/corpus, tools/lookup ],
  schema = ${inputs.schema},
  max_rounds = 6
) @answer
return { value = ${result.value}, rounds = ${result.rounds} }
```

**`submit` rules** (tell the model explicitly in `system` / `## agent`):

1. **Mandatory** — finishing with plain text instead of `submit` is a hard
   `llm` error. Only `submit` ends the loop.
2. **Alone** — `submit` must be the **only** tool call in its round. A round
   mixing `submit` with other calls is rejected wholesale: no tools run, and
   the model gets a recoverable message to call `submit` alone.
3. **Recoverable decode** — if `submit` arguments fail schema validation, the
   engine feeds back a tool message (`submit decode error: …`) and the model
   can retry. This does not abort the run.

Pass `schema` as a JSON Schema object (e.g. from `--input schema=@schema.json`)
or inline in the workflow. See `examples/research/workflows/answer`.

### What the model sees (tool schemas)

Each advertised tool/workflow is translated from its declared **inputs** into
JSON Schema for the provider:

| hwfi type | JSON Schema |
|-----------|-------------|
| `String`, `FileRef` | `string` |
| `Int` | `integer` |
| `Double` | `number` |
| `Bool` | `boolean` |
| `List<T>` | `array` of `T` |
| `Record<{…}>` | `object` with `properties` and `required` |
| `Json` | unconstrained (`{}`) |

The `submit` tool uses the same translation applied to your `schema` argument.

### Agent eligibility

A callee advertised in `tools = [...]` must **not** take:

- `Secret<_>`, `Bytes`, `WorkflowRef`, `ToolRef`
- and must not (transitively) call `builtin/introspect`

Rejected at `hwfi check`, not at runtime. Secrets belong in scripted steps
that pass them to eligible tools — never in agent-advertised callees.

### Tool refs and workflows in the list

Use bare qnames where a `ToolRef` is expected:

```step
tools = [ builtin/read-file, tools/search, workflows/extract ]
```

Sub-workflows run like tools: nested executor step, nested trace, result fed
back to the model as JSON. Same eligibility rules apply.

**Limitation:** `ToolRef` / `WorkflowRef` values work in agent `tools` lists,
but cannot be used as dynamic step call targets in the DSL — a bare `<qname>(...)`
only resolves against top-level binds (`inputs`, `ctx`, prior step results).
Higher-order invocation via bound refs is not available in v1.

### Recoverable vs fatal errors inside agents

The agent loop has a localized error boundary. Design tools accordingly.

| Outcome | Examples | Effect |
|---------|----------|--------|
| **Recoverable** | Unknown tool name; malformed tool args; callee returns error text; `submit` decode failure; `eval-workflow` with `ok = false`; `json-get` with `ok = false` | Tool message to model; loop continues |
| **Fatal** | `max_rounds` exhausted; `llm-agent-object` finishes with plain text; provider/auth failure; workspace lock loss | Run aborts |

Non-zero `exec` exit codes are **values**, not agent-loop errors — branch on
`${result.exit_code}` in the callee or teach the model to read stderr.

### Agent vs scripted orchestration

| Pattern | When to use |
|---------|-------------|
| **Scripted steps** | Fixed pipeline (read → LLM → write) |
| **`llm-agent`** | Model picks tools; free-text answer |
| **`llm-agent-object`** | Model picks tools; **typed JSON** via `submit` |
| **`while`** | Discrete cacheable rounds (check → fix → check) |
| **`llm-gen-object`** | Structured output, **no tools** (zero-tool degenerate case) |

### Resume inside agents

Both `llm-agent` and `llm-agent-object` steps are **non-cacheable** at the
workflow level, but each internal model round and tool call is
content-addressed. Resume replays prior choices without re-calling the provider
or re-running tool side effects. Tool results are cached as actual values;
traces redact secrets. See [caching-and-resume.md](caching-and-resume.md).

---

## Control flow

Control-flow constructs are **value-producing** like step calls.

### `if` / `else`

```step
summary <- if ${inputs.strict} {
  msg <- builtin/exec(program = "sh", args = ["-c", "echo strict"], stdin = "", timeout_ms = 0) @notify
} else {
  msg <- builtin/exec(program = "sh", args = ["-c", "echo lenient"], stdin = "", timeout_ms = 0) @notify
} @mode
```

- Condition must be `Bool`.
- `else` is **required** when the result is bound.
- Both arms must yield the same result type.
- Step `@id`s may repeat across arms; the executor scopes them in cache keys.

### `foreach`

Sequential loop; preserves order.

```step
rows <- foreach task in ${task_list.tasks} {
  built <- workflows/build(spec = ${inputs.spec}, task = ${task}) @build
} @buildloop
```

- `task_list.tasks : List<T>` binds `task : T` in the body.
- Value: `List<U>` where `U` is the body's last statement type.
- `_ <- foreach ...` discards the list (side effects only).

### `par`

Parallel loop with bounded concurrency (default 4).

```step
checks <- par(max = 4) path in ${inputs.scripts} {
  c <- builtin/exec(program = "sh", args = ["-n", ${path}], stdin = "", timeout_ms = 0)
} @check
```

- Results are in **input order**, not completion order.
- Aborts on the **lowest-index** failure.

### `while`

Predicate/body loop with separate sub-workflows:

```step
results <- while(
  predicate = workflows/check_done,
  predicate_args = { target = ${inputs.target} },
  body = workflows/refine,
  body_args = { target = ${inputs.target} },
  max_iterations = 20
) @refine_loop
```

**Predicate outputs** must include `continue: Bool` and `reason: String`.
`reason` is logged in the trace for debugging; the engine does not interpret it.

**State between iterations:**

1. Workspace mutations (primary pattern).
2. Re-evaluated `predicate_args` / `body_args` from the enclosing scope.
3. `${carry}` — previous body result (not in scope on iteration 0; referencing
   it there is a static type error).

Reaching `max_iterations` without `continue = false` aborts the run with a
`user` error.

**Resume** — predicate `continue` decisions are pinned per iteration (`while-pred`
events). On resume, a cached decision skips re-running the predicate workflow for
that iteration. See [caching-and-resume.md](caching-and-resume.md).

### Scoping in blocks

- Inner bindings do not escape the block.
- Outer bindings are visible inside.
- No shadowing of outer names inside a block.
- `@step-id` unique within a block; may repeat in sibling branches.

---

## Skills

Skills live under `skills/` and register in the project catalog at `hwfi check`
time. Two kinds:

- **`callable`** (default) — full tool/workflow declaration; can be advertised
  to agents once checked.
- **`instruction`** — prose only (no `step` blocks); injected into agent context.

Optional `project.json` limits:

```json
"skills": {
  "directory": "skills",
  "max_callable_loads": 8,
  "max_instruction_loads": 5,
  "max_instruction_chars": 12000
}
```

Baseline `tools` in the agent step do not count toward load caps.

### Instruction skill

Prose guidance loaded into an agent's context:

```yaml
---
name: skills/typescript-vite-guide
skill:
  kind: instruction
  summary: Scaffold TypeScript + Vite
  tags: [typescript, vite]
---
# TypeScript + Vite guide
...
```

Load via `discover-skills` + `load-skill` inside an agent, or concatenate the
returned `content` into `system` before the agent step.

### Callable skill

Same shape as a tool/workflow (default `kind: callable`). Advertise statically
in `tools = [...]` or load dynamically mid-loop (see below).

### Runtime discovery and loading

Agents that discover skills dynamically must **explicitly** include the meta-tools
in their `tools` list — there is no implicit injection:

```step
tools = [
  builtin/discover-skills,
  builtin/load-skill,
  builtin/read-file,
  ...
]
```

Typical loop behaviour:

1. **`discover-skills`** — model searches the catalog; results are a normal tool
   message. Use short query keywords (`vite`, `haskell`), not long phrases.
2. **`load-skill` for instruction** — body is injected as a synthetic system
   message (`## Loaded skill: <id>`) before the next model round.
3. **`load-skill` for callable** — skill joins the **active tool set** on the
   next round if `checked` and `agent_eligible`. `loaded = false` if already
   active (idempotent).

`load-skill` outside an agent returns instruction bodies in `content` without
mutating any loop. Callable skills loaded outside an agent do not become tools.

### Discovery tips

- Tag matching is bidirectional on individual words.
- Prefer one keyword per `discover-skills` call.
- See `examples/ship/workflows/build` and `examples/skills-runtime`.

---

## Context (`ctx`)

Every workflow and tool receives ambient `ctx : Context` (not declared as an
input):

| Field | Content |
|-------|---------|
| `ctx.workspace` | Workspace root as `FileRef` |
| `ctx.run.id` | Run identifier |
| `ctx.run.started_at` | ISO timestamp |
| `ctx.run.entrypoint` | Qname of entry workflow |
| `ctx.self.qname` | Current declaration |
| `ctx.self.step_id` | Current step id |
| `ctx.inputs` | Root workflow inputs as `Json` |
| `ctx.trace` | Events so far in this run |
| `ctx.env` | Whitelisted env vars from `project.json` |

Referencing `ctx.trace` or `ctx.run.started_at` in step arguments makes the
step **non-cacheable**.

### Secrets and `ctx.env`

Whitelisted env vars are typed as `String`, except names matching
`*_KEY`, `*_TOKEN`, `*_SECRET`, `*_PASSWORD` (case-insensitive), which become
`Secret<String>` automatically.

- **`Secret<T>`** cannot be interpolated into plain strings — pass to a tool
  parameter declared `Secret<T>`.
- Traces redact `Secret<_>` fields as `"<secret:$name>"`.
- Provider API keys (`DEEPSEEK_API_KEY`, etc.) are **not** `ctx.env` unless
  whitelisted (discouraged). They are loaded separately for LLM calls.

Example: `examples/research` passes `RESEARCH_API_TOKEN` from `ctx.env` into
`tools/authorize` while keeping it out of agent tool lists.

---

## Running workflows

### Check

```bash
hwfi check <project-dir>
```

Parse + type-check only. Fix all errors before running. Errors use
`file:line:col:` format for editor navigation.

### Run

```bash
hwfi run <project-dir> --workspace <dir> \
  [--env-file <path>] \
  [--input <key>=<value>]... \
  [--input <key>=@<file.json>]... \
  [--input-json <file.json>] \
  [--entry <qname>]
```

| Flag | Effect |
|------|--------|
| `--workspace` | Sandbox directory (created if needed). Run artifacts: `.hwfi/runs/<id>/` |
| `--input k=v` | String input field |
| `--input k=@file.json` | JSON value from file |
| `--input-json file` | Whole inputs record; per-`--input` overrides |
| `--entry` | Override `project.json` `entrypoint` |
| `--env-file` | Provider keys; overrides project `.env` and defaults |

**FileRef inputs** are workspace-relative paths, e.g. `--input path=article.txt`.

**Structured inputs** — pass JSON from a file with `@`:

```bash
--input schema=@examples/research/schema.json
--input-json inputs.json   # whole inputs record; per --input overrides
```

### Resume

```bash
hwfi resume <workspace-dir> <run-id>
```

Re-executes from the last incomplete point, reusing cached step results.

### Show trace

```bash
hwfi show <workspace-dir> <run-id>
```

Pretty-prints the trace and usage summary. Secrets are redacted.

### Clear cache

```bash
hwfi cache clear <workspace-dir> <run-id>
```

Deletes cached step results so the next resume recomputes cacheable steps.

---

## Workspace layout at runtime

```
<workspace>/
  ... your project files ...
  .hwfi/
    runs/
      <run-id>/
        run.json          # inputs, usage, metadata
        trace.jsonl       # append-only event log
        steps/            # content-addressed step results
```

- All file builtins resolve paths **inside** the workspace (no traversal).
- The workspace is durable across resume; treat it as the source of truth for
  file mutations.

---

## Model catalog

Every project needs `model-catalog.json` at the root:

```json
[
  {
    "modelConfigName": "default",
    "providerName": "deepseek",
    "modelName": "deepseek-v4-flash",
    "pricing": { "pricePerMillionInput": 0.14, "pricePerMillionOutput": 0.28 },
    "maxTokens": 1024,
    "temperature": 0.3,
    "requestTimeout": 60000,
    "throttleDelay": 0,
    "retryCount": 2,
    "jitterBackoff": 1000
  }
]
```

Use `model = "default"` (or any `modelConfigName`) in LLM builtins. Unknown
names fail at runtime with a list of available entries.

Editing catalog fields (except `pricing`) invalidates cached LLM step keys.

---

## Provider keys and env

Provider API keys (`OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, etc.) are loaded by
hwfi for LLM calls. They do **not** flow through `ctx.env` unless you also
whitelist them in `project.json` `env` (discouraged).

Load order (first wins for keys):

1. `--env-file`
2. `<project>/.env`
3. Process environment
4. `$XDG_CONFIG_HOME/hwfi/.env`

**`project.json` `env` whitelist** — if you list `MY_FLAG`, it must be set at
`hwfi run` startup or the run aborts before any step. There is no optional env
in v1.

---

## Caching (essentials)

- Cacheable steps skip re-execution on resume when inputs, code fingerprint,
  and relevant `ctx` fields match.
- **Non-cacheable:** `llm-agent`, `llm-agent-object`, `introspect`, `log`,
  `eval-workflow`, `load-skill`, trace builtins (`list-runs`,
  `read-run-trace`, `trace-slice`), steps referencing `ctx.trace` or
  `ctx.run.started_at`.
- **Workspace vs cache:** cache stores step *outputs*, not a snapshot of all
  files. A cached `read-file` does not re-read disk.
- **Code edits** invalidate via Merkle fingerprints — no manual busting needed
  for declaration changes.
- **Agent replay** — agent steps re-walk the loop on resume; cached model rounds
  and tool calls replay without provider calls or side effects.
- **`while` pinning** — predicate `continue` decisions are cached per iteration.
- Full detail: [caching-and-resume.md](caching-and-resume.md).

---

## Common patterns

### Read → LLM → write

`examples/summarise` — minimal pipeline with `@self#system`.

### Agent coding loop

`examples/coding` — `llm-agent` with `read-file`, `edit-file`, `exec`.

### Typed agent with `submit`

`examples/research/workflows/answer` — `llm-agent-object` with read-only tools
and a caller-supplied `schema`; model must call `submit` alone to finish.

```bash
cabal run hwfi -- run examples/research \
  --workspace /tmp/research-ws \
  --entry workflows/answer \
  --input question="Summarise the distributed-systems doc." \
  --input schema=@examples/research/schema.json
```

### Skill discovery in agents

`examples/skills-runtime` — minimal `discover-skills` + `load-skill` toolbox.
`examples/ship/workflows/build` — full coding agent with dynamic skill loading.

### Full feature tour

`examples/research` — all LLM builtins, secrets, `ctx.trace`, structured CLI
inputs, sub-workflows, and both agent variants (`investigate` / `answer`).

### Control flow showcase

`examples/control-flow` — `par`, `foreach`, `if`, and `while` entrypoints.

### Plan → foreach build → review

`examples/ship` — `llm-gen-object` planning, `foreach` over tasks,
sub-workflow agents with skill discovery.

### Bridge JSON objects to lists

When an LLM returns `tasks` as a JSON object keyed `"0"`, `"1"`, …, use
`builtin/json-values` to collect values into `List<Json>` for `foreach` (see
`examples/ship/tools/plan-tasks.md`). Null entries are omitted automatically.

```step
got <- builtin/json-values(json = ${plan.plan}, path = "tasks")
rows <- foreach task in ${got.values} {
  ...
}
```

Works on JSON arrays too (elements in order, nulls dropped). An empty `path`
uses the root `json` value directly.

### Structured planning

`builtin/llm-gen-object` with a prose schema in the prompt and `schema = null`
(or an explicit JSON schema when you have one).

---

## Errors and debugging

1. **`hwfi check`** — fix type and reference errors first.
2. **`hwfi show`** — follow `step-start` / `step-end`, `exec`, `llm-call`,
   `agent-tool-call`, `while-pred`, loop events.
3. **Static locations** — error messages cite the `step` block line/column.
4. **Runtime errors** — include `qname` and `step_id` matching the trace.
5. **Agent round cap** — `max_rounds` exhausted → fatal `llm` error; increase
   cap or tighten the prompt.
6. **Typed agent** — plain-text finish without `submit` → fatal `llm` error;
   mixed `submit` round → recoverable (no tools run); bad `submit` args →
   recoverable decode message.
7. **`while` cap** — `max_iterations` reached with `continue = true` → fatal
   `user` error.

`builtin/json-get`, `eval-workflow`, and many agent tool failures return
`ok = false` (or error text) instead of aborting — design workflows and agent
prompts to handle those paths when needed.

---

## v1 limitations

Not available in v1 (see spec §13):

- Workflow-level `try` / recover
- `Optional<T>` / nullable env
- Record map/filter/merge helpers (partial: `json-get`, `json-values`, `concat` exist)
- Step cache does not include workspace file contents
- No arbitrary HTTP builtin (only LLM provider calls + allowlisted `exec`)

---

## Further reading

| Resource | Content |
|----------|---------|
| [spec.md](spec.md) | Full normative specification |
| [caching-and-resume.md](caching-and-resume.md) | Cache and resume semantics |
| [tool-use.md](tool-use.md) | Agent tool-loop design rationale (incl. `submit`) |
| [examples/summarise/README.md](../examples/summarise/README.md) | Tutorial 1 |
| [examples/coding/README.md](../examples/coding/README.md) | Agent + resume |
| [examples/research/README.md](../examples/research/README.md) | Full feature tour + typed agent |
| [examples/ship/README.md](../examples/ship/README.md) | Full orchestration |
| [examples/skills-runtime/README.md](../examples/skills-runtime/README.md) | Skill discover/load |
| [examples/control-flow/README.md](../examples/control-flow/README.md) | Control flow |
