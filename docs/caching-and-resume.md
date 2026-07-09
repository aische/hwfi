# Caching and resume — author guide

hwfi persists every run under `<workspace>/.hwfi/runs/<run-id>/`. Resume reuses
**cached step results** so completed work is not repeated. This guide explains
what is cached, what is not, and the surprises that matter when writing
workflows and tutorials.

Normative detail: spec §8.1–§8.3.

## Step cache basics

A **cacheable** step computes a **step-key** from:

- the callee qname and `@step-id`
- evaluated argument values (secrets hashed, not logged)
- stable `ctx` fields the step references
- the callee's Merkle **fingerprint** (code edits invalidate downstream cache)

If a matching file exists under `steps/<step-key>.json`, resume **skips** the
step: no new trace events, no re-execution.

**Non-cacheable** steps always re-run on resume:

- `builtin/introspect`
- `builtin/llm-agent` / `builtin/llm-agent-object` (the step as a whole)
- `builtin/eval-workflow`, `builtin/list-runs`, `builtin/read-run-trace`,
  `builtin/trace-slice`
- `builtin/log`
- any step whose arguments reference volatile `ctx` fields (`ctx.trace`,
  `ctx.run.started_at`, `ctx.run.usage`)

## Workspace vs cache

The **workspace** is durable state across a run and resume. The **step cache**
stores *results*, not file contents.

| Situation | Behaviour |
|-----------|-----------|
| `write-file` / `edit-file` completed and cached | File already on disk; write not re-applied |
| `read-file` cached | Returns cached text; does **not** re-read disk |
| You edit a workspace file **outside** the workflow | Cached `read-file` may return stale content |
| You edit workflow **source** | Fingerprints change; affected steps re-run |

**Rule:** treat the workspace as the source of truth for mutations; treat the
cache as memoization of step *outputs* for unchanged code and inputs.

To force recomputation during development, use `hwfi cache clear <workspace> <run-id>`
or start a fresh run id.

## Agent steps

An agent step (`builtin/llm-agent`) is a **non-cacheable black box** at the
workflow level. Inside it, each **model call** and **tool call** has its own
sub-key under the agent step-key.

On **resume**:

1. The agent step re-executes (re-walks the loop).
2. Cached model rounds replay without calling the provider.
3. Cached tool calls replay without re-running side effects.
4. A miss anywhere re-runs from that point forward.

This is why a resumed coding agent does not re-pay LLM calls or re-apply edits
it already made — see `examples/coding/README.md`.

Tool results are stored in the cache as **actual values**; traces redact
secrets (§5.5).

## Control-flow scopes

`foreach`, `par`, and `while` fold an iteration/branch prefix into step-keys
(`#i/…`, `#i/p/`, `#i/b/`). Each iteration's steps cache independently on
resume.

`while` predicate decisions are pinned per iteration (`while-pred` events) so
resume does not re-invoke the predicate workflow when the decision is cached.

## Environment and inputs

- Inputs are fixed for a run (`run.json`).
- Whitelisted `project.json` `env` variables must be **present at startup**
  (strict presence, §5.7). There is no `Optional<T>` in v1.
- Changing `model-catalog.json` invalidates one-shot LLM step-keys that name
  the affected catalog entry.

## Inspecting runs

```bash
cabal run hwfi -- show <workspace> <run-id>
```

Shows the trace with secrets redacted. Step results under `steps/` hold actual
(non-redacted) values for resume.

## When automatic invalidation is enough

Merkle fingerprints handle **declaration edits** transitively. You do **not**
need manual cache busting when you change workflow/tool markdown.

You **may** need manual busting when:

- workspace files changed but step inputs and code did not
- you are re-running tutorial steps against an old run dir
- you suspect a corrupted `steps/` entry after a crash
