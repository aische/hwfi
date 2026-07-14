# `webapp` — build a web app from a prompt at runtime

Starting from an **empty workspace**, an LLM coding agent authors a
self-contained `index.html` implementing whatever app you describe in a prompt.
Nothing is copied — the model writes the HTML/CSS/JS itself, then self-checks it
with an allowlisted command and edits until the check passes. It exercises the M7
mutation + `exec` builtins (spec §6.2, §6.3) inside the agentic tool-use loop
(spec §6.1).

## How the prompt flows in

Your `--input spec=...` becomes the agent's task. In `workflows/build`:

```
prompt = ${inputs.spec}
```

is handed to `builtin/llm-agent` as the model's user turn, and the model then
calls `write-file` / `read-file` / `edit-file` / `exec` autonomously to produce
and verify the app.

## The `exec` policy (spec §7.5)

`builtin/exec` is fail-closed: it runs nothing unless `project.json` opts in. Here
only `sh` is allowlisted, the child sees only `PATH`, and calls are bounded by a
timeout and an output cap:

```json
"exec": { "allow": ["sh"], "env": ["PATH"], "timeout_ms": 15000, "max_output_bytes": 65536 }
```

## Prerequisites

The default catalog uses local **Ollama** (no API key). Make sure it is running
and the model is pulled:

```bash
ollama pull mistral:latest   # catalog entry "smart"
```

A stronger hosted model produces better single-file apps; edit `model-catalog.json`
and supply the key via `<project>/.env` or `--env-file` (spec §7.2). See the
tuning note below on why model strength matters here.

## Running it

```bash
# Start from a genuinely empty workspace:
mkdir -p /tmp/webapp-ws

cabal run hwfi -- run examples/webapp \
  --workspace /tmp/webapp-ws \
  --input spec="A canvas drawing app: full-window canvas, color picker, brush-size slider, Clear and Save-PNG buttons, mouse and touch support"

# Try any other app:
cabal run hwfi -- run examples/webapp \
  --workspace /tmp/webapp-ws \
  --input spec="A pomodoro timer with start/pause/reset and a circular progress ring"

# Open the result in a browser:
open /tmp/webapp-ws/index.html
```

Inspect the trace to see the agent's file writes and verification commands nested
under the agent step:

```bash
cabal run hwfi -- show /tmp/webapp-ws <run-id>
```

## Notes / limits

- **Needs a live LLM** — this is runtime generation, so it is non-deterministic.
  (For a deterministic mutation + `exec` demo see [`../coding`](../coding).)
- **Whole-file writes are bounded by the model's output budget.** `write-file`
  sends the entire file as one tool-call argument, capped by `maxTokens` in the
  catalog; large apps favour incremental `edit-file` edits, or raise `maxTokens`.
  Small local models struggle with big single-shot files — prefer a strong model.
- **`exec` is allowlisted.** The self-check can only use what `exec.allow`
  permits (here `sh`); add programs there to let the agent run richer checks.
- **`max_rounds`** bounds the write → check → fix loop; exhausting it fails the
  step (spec §6.1.4).

## Resume behaviour (spec §8)

The agent step is a non-cacheable black box (static classification). Resume
continues from `CurAgent` state in `machine.json` — prior rounds and tool
calls are not replayed from a step cache.
