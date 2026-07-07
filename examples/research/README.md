# `research` — a feature-rich example project

A "document research digest" pipeline that exercises almost every capability of
the workflow interpreter in one coherent workflow. Compared to
[`../summarise`](../summarise) (a minimal two-step pipeline), this project is
deliberately complex: multiple workflows and tools, shared type aliases, all
LLM built-ins, structured (`Json`) inputs, secrets, and non-cacheable
introspection steps.

## What it does

Given a target document and a corpus directory, it:

1. **Authorizes** the run against a secret token (`tools/authorize`).
2. **Lists** the corpus directory (`builtin/list-dir`).
3. **Reads** the target document (`builtin/read-file`).
4. **Extracts** structured metadata as JSON conforming to a caller-supplied
   schema (`workflows/extract` → `builtin/llm-gen-object`).
5. **Builds a headline** from a typed `types/doc-brief` record (`tools/headline`).
6. **Summarises** the document (`builtin/llm-generate`, `@self#summariser`).
7. **Refines** the draft over a multi-turn conversation
   (`workflows/critique` → `tools/converse` → `builtin/llm-chat`).
8. **Writes** the digest to `digest.md`.
9. **Audits** the run into `audit/` using non-cacheable observation steps
   (`workflows/audit` → `builtin/introspect` + `ctx.trace`).

## Feature coverage

| Feature (spec §)                                   | Where                                             |
|----------------------------------------------------|---------------------------------------------------|
| Multiple workflows + sub-workflow calls (§4, A6)   | `main` calls `extract`, `critique`, `audit`       |
| User-defined tools                                 | `tools/authorize`, `tools/converse`, `tools/headline` |
| Shared type aliases (§2.1, A10)                    | `types/message`                                    |
| **Nested** alias (alias → alias)                   | `types/chat-log` = `List<types/message>`          |
| Record type alias + checked field access (§5.6.7)  | `types/doc-brief` in `tools/headline`             |
| `builtin/read-file`, `write-file`, `list-dir` (§6) | `main`, `audit`                                    |
| `builtin/llm-generate` (§6)                        | `main` step `@summary`                            |
| `builtin/llm-chat` multi-turn (§6, A16)            | `tools/converse`                                  |
| `builtin/llm-gen-object` with `Json` schema (§6)   | `workflows/extract`                               |
| `builtin/llm-agent` tool-use loop (§6.1, A17)      | `workflows/investigate` advertises `tools/corpus`, `tools/lookup` |
| `builtin/llm-agent-object` typed `submit` (§6.1.3) | `workflows/answer` with a caller-supplied schema  |
| Agent tool eligibility + non-cacheable step (§6.1.1, §8.1) | `tools/corpus`, `tools/lookup` (read-only, `String` inputs) |
| `builtin/introspect` (non-cacheable, §8.1)         | `workflows/audit`                                 |
| `@self#heading` prompt references (§3.2, A9)       | `summariser`, `extractor`, `reviewer` sections    |
| `ctx.env` string value (§5.7)                      | `RESEARCHER_NAME`                                 |
| `ctx.env` secret value + redaction (§5.5, A8)      | `RESEARCH_API_TOKEN` → `tools/authorize`          |
| `ctx.trace` read → non-cacheable step (§8.1, A7)   | `workflows/audit` step `@tracefile`               |
| `ctx.run.id` stable field                          | `workflows/audit`                                 |
| Structured `Json` CLI input (§9)                   | `--input schema=@schema.json`                     |
| String interpolation of `List`/`Json` (§3.2.1)     | headline, digest, audit                           |
| Bare vs. interpolated references (§3.2.1)          | `messages = ${inputs.history}` vs. `"...${x}..."` |
| Multi-line strings `"""…"""`                        | `main` prompt and digest body                     |
| Record & list literals                             | `main` (doc-brief), `critique` (chat history)     |
| Explicit `return { … }`                            | every workflow/tool                               |
| Discard binder `_` and explicit `@step-id`s        | throughout `main`                                 |
| Step-DSL comments (`--`)                           | throughout `main`                                 |

## LLM tool-use (agentic workflows, spec §6.1)

Two alternate entrypoints demonstrate LLM-driven tool use, where the model — not
a fixed script — decides which of the project's own declarations to call:

- **`workflows/investigate`** (`builtin/llm-agent`): advertises the read-only
  `tools/corpus` and `tools/lookup` tools and lets the model explore the corpus
  and answer a free-text question.
- **`workflows/answer`** (`builtin/llm-agent-object`): the same tools plus a
  synthetic `submit` tool whose parameters are a caller-supplied JSON schema; the
  loop ends only when the model calls `submit` alone, yielding a typed `Json`.

Only agent-eligible declarations may be advertised: a candidate tool's inputs
must not contain `Secret<_>`, `ToolRef`/`WorkflowRef`, or `Bytes`, and it must
not (transitively) reach `builtin/introspect` (spec §6.1.1, §6.1.5). The agent
step itself is a non-cacheable black box (§8.1), but each model round and tool
call inside it is content-addressed, so a resumed run replays the model's prior
choices and tool results without re-paying the LLM (§8.2.1).

```bash
# Free-text agent (choose the entrypoint with --entry):
cabal run hwfi -- run examples/research \
  --workspace /tmp/research-ws \
  --entry workflows/investigate \
  --input question="How does quantum error correction relate to fault tolerance?"

# Typed-output agent (submit conforms to schema.json):
cabal run hwfi -- run examples/research \
  --workspace /tmp/research-ws \
  --entry workflows/answer \
  --input question="Summarise the distributed-systems doc." \
  --input schema=@examples/research/schema.json
```

> **Note on first-class refs.** `ToolRef`/`WorkflowRef` types exist in v1
> (§5.1) but, as currently implemented, cannot be *invoked* as a call target:
> a bare call target only resolves against top-level roots (`inputs`, `ctx`,
> prior binds), and every step bind is a record, so a ref value can never end
> up bound as a callable name. This example therefore does not demonstrate
> higher-order invocation; it is a genuine engine limitation, not an omission.

## Prerequisites

The default `model-catalog.json` uses the local **Ollama** provider (no API key
required). Make sure Ollama is running and the referenced models are pulled:

```bash
ollama pull llama3.2:latest   # catalog entry "fast"
ollama pull mistral:latest    # catalog entry "smart"
```

To use a hosted provider instead, edit `model-catalog.json` and provide the key
via `<project>/.env` (copy `.env.example`) or `--env-file` (spec §7.2).

## Running it

Two environment variables are whitelisted in `project.json` and are **required**
to be present at startup (strict presence, spec §5.7). One is auto-typed as a
secret because its name ends in `_TOKEN`:

```bash
export RESEARCHER_NAME="Ada Lovelace"
export RESEARCH_API_TOKEN="does-not-matter-for-ollama"

# Use a scratch workspace so run artifacts don't land in the repo:
cp -r examples/research/sample-workspace /tmp/research-ws

cabal run hwfi -- run examples/research \
  --workspace /tmp/research-ws \
  --input doc=docs/quantum-computing.md \
  --input docs_dir=docs \
  --input schema=@examples/research/schema.json
```

Equivalently, supply the whole inputs record as JSON:

```bash
cabal run hwfi -- run examples/research \
  --workspace /tmp/research-ws \
  --input-json examples/research/inputs.example.json
```

On success the workflow prints its output record as JSON
(`{ "digest": …, "report_path": "digest.md" }`) and the workspace contains:

```
digest.md                 # the rendered research digest
audit/introspection.json  # builtin/introspect dump
audit/trace.txt           # ctx.trace snapshot
.hwfi/runs/<run-id>/       # run.json, steps/, trace.jsonl
```

## Inspecting a run

```bash
# Pretty-print the trace (note the redacted <secret:RESEARCH_API_TOKEN>):
cabal run hwfi -- show /tmp/research-ws <run-id>

# The cleartext token never appears in the trace:
grep -c "does-not-matter-for-ollama" /tmp/research-ws/.hwfi/runs/*/trace.jsonl   # -> 0
```

## Resume behaviour

If a run is interrupted, resume it:

```bash
cabal run hwfi -- resume /tmp/research-ws <run-id>
```

Cacheable steps with a persisted result are skipped and emit no new trace
events, while the `workflows/audit` steps (which read `ctx.trace` / call
`introspect`) are always re-executed (spec §8.2, A7).
