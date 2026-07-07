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
5. Is designed so that, in a later stage, agent steps can synthesize new
   workflows at runtime and read prior traces.

Non-goals for v1: GUI, remote/distributed execution, multi-tenant isolation,
a package registry for workflows.

## 2. Project layout (input)

A workflow project is a directory with:

```
project.json                # project manifest (name, entrypoint, version)
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
  fully-qualified name.

## 3. Markdown workflow syntax (v1)

A workflow markdown file has:

1. **YAML frontmatter** with typed `inputs`, `outputs`, and optional `imports`
   (other workflows/tools to bring into scope).
2. A **body** consisting of ordered numbered/bulleted steps. Each step is either
   prose (documentation, ignored by executor) or a **step block**: a fenced
   code block with `lang=step` and a small JSON/YAML payload describing:
     - `id`: stable identifier, unique within the workflow
     - `call`: fully-qualified name of a tool or sub-workflow
     - `args`: arguments (literals or `${expr}` references to prior step outputs
       or workflow inputs)
     - `bind`: name to bind the result to (must match declared outputs if this
       is the final step)
3. Prompt/system-message content for LLM-backed tools lives in the surrounding
   markdown of the tool's own file, not inside step blocks.

Example (illustrative, exact grammar TBD in task 3.x):

````markdown
---
name: summarise-file
inputs:
  path: FileRef
outputs:
  summary: String
imports:
  - tools/read-file
  - tools/llm-summarise
---

1. Read the file.

```step
{ "id": "read", "call": "tools/read-file",
  "args": { "path": "${inputs.path}" }, "bind": "contents" }
```

2. Summarise it.

```step
{ "id": "sum", "call": "tools/llm-summarise",
  "args": { "text": "${contents.text}" }, "bind": "summary" }
```
````

**[open]** exact frontmatter schema, exact step block language (JSON vs YAML),
expression sub-language for `${...}` (accessors only vs. small pure lambda).
Default choice for v1: JSON step payloads, accessor-only expressions
(`${name}`, `${name.field}`, `${name[0]}`), no arithmetic or conditionals in
expressions.

## 4. Control flow (v1)

- Sequential steps only.
- **[open, v1.1]** `foreach`, `if`, `while`, parallel `par` blocks. Not in v1.
- Errors abort the workflow; the failing step is recorded and the run is
  resumable from that step.

## 5. Type system (v1)

Types are declared in frontmatter and tool signatures. Base types:

- `String`, `Int`, `Double`, `Bool`
- `Json` (opaque structured value)
- `FileRef` (path inside the workspace; existence not required at type-check
  time, only when read)
- `List<T>`, `Record<{ field: T, ... }>`
- `WorkflowRef<in, out>`, `ToolRef<in, out>` (first-class references, needed
  for dynamic workflow generation in v2)

Type-checking rules:

1. Every step's `call` target must resolve to a declared workflow/tool.
2. `args` structure must match the callee's declared `inputs`.
3. `${expr}` references are checked against the binding environment built from
   `inputs` and prior `bind`s.
4. The last step (or an explicit `return` block) must produce values matching
   the workflow's declared `outputs`.
5. Cycles between workflows (workflow A imports B imports A transitively as a
   call target) are detected and rejected, unless behind a `WorkflowRef` (i.e.
   passed as a value, not directly called).

## 6. Built-in tools (v1)

Provided by the engine, addressed as `builtin/<name>`:

- `builtin/read-file` : `{ path: FileRef } -> { text: String }`
- `builtin/write-file` : `{ path: FileRef, text: String } -> {}`
- `builtin/list-dir` : `{ path: FileRef } -> { entries: List<String> }`
- `builtin/llm-generate` : `{ system: String, prompt: String, model?: String }
  -> { text: String }` (backed by `llm-simple` `Generate.generateTextWithFallbacks`)
- `builtin/llm-gen-object` : `{ system: String, prompt: String, schema: Json,
  model?: String } -> { value: Json }` (backed by `genObject`/`genObjectUntyped`)

**[open]** shell execution tool. Deferred to v1.1 for safety.

## 7. Workspace and sandboxing

- Engine receives `--workspace <dir>` on the CLI.
- All `FileRef` values are resolved relative to the workspace root.
- Path traversal outside the workspace is rejected at runtime; the workspace
  root is canonicalised once at start.
- The workspace is the **only** filesystem area the workflow may write to.
- The project directory (workflows/tools) is read-only during execution.

## 8. Persistence and resumability

Every run has a `run id` (ULID). Run artifacts are stored under
`<workspace>/.wfe/runs/<run-id>/` (name **[open]**: `.wfe` placeholder):

```
run.json          # run metadata: project hash, entrypoint, inputs, status
steps/
  <step-key>.json # one file per completed step
trace.jsonl       # append-only event log (start, step-start, step-end,
                  # llm-call, file-io, error)
```

- `step-key` = stable hash of `(workflow qualified name, step id, resolved
  argument values)`. Steps are content-addressed: on resume, if a `step-key`
  already has a persisted result, it is reused without re-execution.
- LLM calls inside a step are part of the step; a step is atomic. Partial
  LLM output is not resumed mid-call.
- A run is **resumable** if `run.json.status ∈ {running, crashed, aborted}`.
  Resume replays the workflow, skipping any step whose key hits the cache.

Determinism note: because `step-key` includes resolved argument values, and
LLM outputs are captured in the step result, replays after resume are
deterministic w.r.t. cached steps. New steps re-invoke the LLM as normal.

## 9. CLI

Minimal v1 surface:

```
wfe check   <project-dir>
wfe run     <project-dir> --workspace <dir> [--input k=v]... [--entry <name>]
wfe resume  <workspace-dir> <run-id>
wfe show    <workspace-dir> <run-id>          # pretty-print trace
```

`wfe check` performs parse + type-check only, exits non-zero on any error.
Command name **[open]**.

## 10. Dependencies and tooling

- GHC2021.
- Cabal project. `llm-simple` referenced as a local `packages:` entry pointing
  at `../llm-simple` via `cabal.project`.
- Libraries expected: `aeson`, `text`, `bytestring`, `containers`,
  `filepath`, `directory`, `unliftio` or `async`, a markdown parser
  (**[open]**: `cmark-gfm` vs. `commonmark-hs` vs. hand-rolled — decision in
  task 2.1), `optparse-applicative`, `ulid` or `uuid`, `cryptonite`/`hashable`
  for step-key hashing.

## 11. Acceptance criteria (v1)

A1. `wfe check` on a well-formed project exits 0 and prints nothing on stderr.
A2. `wfe check` on a project with an undeclared reference, type mismatch, or
    import cycle exits non-zero with a message pointing at file and step id.
A3. `wfe run` on a two-step sample workflow (`read-file` → `llm-generate`)
    produces the expected output file in the workspace and a populated
    `.wfe/runs/<id>/` directory.
A4. Killing the process mid-run and invoking `wfe resume` completes the run
    without re-executing already-persisted steps (verified by a step that
    writes a marker file and would double-write on re-execution).
A5. Attempting to write to a path outside the workspace fails with a clear
    error and is recorded in the trace.
A6. A workflow can call another workflow as a step; type-checking enforces
    the callee's signature.

## 12. Edge cases and known tricky bits

- Non-UTF-8 files in the workspace: read as bytes, expose as `Bytes` **[open,
  v1.1]**; v1 treats read-file as text and errors on invalid UTF-8.
- Very large LLM outputs: step results are written to disk, not held in RAM
  beyond the current step's needs.
- Renaming a workflow file mid-project changes qualified names and therefore
  invalidates cached step keys — acceptable, documented.
- Concurrent runs sharing a workspace: v1 requires an exclusive lock file
  under `.wfe/`; second `run` fails fast.
- Circular tool imports: rejected at type-check.

## 13. Explicitly deferred to v1.1+

- Control flow (`if`, `foreach`, `par`).
- Shell/exec tool.
- Dynamic workflow synthesis by agents (requires `WorkflowRef` values to be
  constructable from `Json`, and a runtime type-check pass).
- Reading own trace as a workflow input (introspection tool).
- Skill extraction from traces.
