# `coding` — mutation + `exec` example

Demonstrates the M7 capabilities: filesystem **mutation** builtins (spec §6.2)
and allowlisted command **execution** (`builtin/exec`, spec §6.3, §7.5), in both
a fixed *scripted* workflow and an *agentic* coding loop.

Two entrypoints:

- **`workflows/render`** (scripted, the default entrypoint): edits a template in
  place with `builtin/edit-file`, then runs the rendered script with
  `builtin/exec` and returns its captured `stdout` and `exit_code`. No LLM
  involved — a deterministic mutation → exec pipeline.
- **`workflows/fix`** (agentic): a `builtin/llm-agent` coding loop that advertises
  `builtin/read-file`, `builtin/grep`, `builtin/edit-file`, and `builtin/exec` to
  the model and lets it repair a shell script whose `sh -n` syntax check fails —
  reading, editing, and re-running until the build passes.

## The `exec` policy (spec §7.5)

`builtin/exec` is **fail-closed**: it runs nothing unless `project.json` opts in
with an `exec` policy. Here only the `sh` program is allowlisted, the child sees
only `PATH` from `hwfi`'s environment (never provider API keys), and each call is
bounded by a wall-clock timeout and an output cap:

```json
"exec": {
  "allow": ["sh"],
  "env": ["PATH"],
  "timeout_ms": 10000,
  "max_output_bytes": 65536
}
```

`hwfi check` rejects any `builtin/exec` call whose literal `program` is not in
`allow`, and rejects `exec` entirely when no policy is configured (spec §7.5,
A24). A non-zero exit is a *value* (`exit_code`), not a run error, so a workflow
or agent can react to a failing build (spec §6.3).

## Running the scripted pipeline

```bash
# Use a scratch workspace so run artifacts don't land in the repo:
cp -r examples/coding/sample-workspace /tmp/coding-ws

cabal run hwfi -- run examples/coding \
  --workspace /tmp/coding-ws \
  --input name="Ada"
```

Output:

```json
{"exit_code":0,"greeting":"Hello, Ada!\n"}
```

Inspect the trace to see the mutation and the command execution:

```bash
cabal run hwfi -- show /tmp/coding-ws <run-id>
# ... file-io   workflows/render#edit  edit hello.sh (…B)
# ... exec      workflows/render#run   sh  exit=0
```

## Running the agentic coding loop

The default catalog uses local **Ollama** (no API key). Make sure it is running
and the referenced models are pulled:

```bash
ollama pull mistral:latest   # catalog entry "smart"
```

Then repair the deliberately broken script (its `if` block is missing `fi`):

```bash
cp -r examples/coding/sample-workspace /tmp/coding-ws

cabal run hwfi -- run examples/coding \
  --workspace /tmp/coding-ws \
  --entry workflows/fix \
  --input target=broken.sh

# Confirm the agent's edit actually fixed the script:
sh -n /tmp/coding-ws/broken.sh && echo "syntax OK"
```

The model drives the loop: it runs `sh -n broken.sh`, sees the error, reads and
edits the file, and re-runs until the check exits 0.

## Resume behaviour (durable workspace, spec §8.2)

Mutation and `exec` steps are cacheable. If a run is interrupted and resumed:

```bash
cabal run hwfi -- resume /tmp/coding-ws <run-id>
```

a completed edit is **not** re-applied and a completed command is **not** re-run
— their results are served from the cache. Inside the agent loop the same holds
per tool call (spec §8.2.1): a resumed loop replays the model's prior choices and
tool results without re-running the mutations or commands.
