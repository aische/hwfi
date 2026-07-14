# Tutorial 3: Agent

Run an **LLM agent loop** that reads, edits, and executes files in a sandboxed
workspace until a shell script passes syntax check.

**Time:** ~15 minutes  
**Example:** [`examples/coding`](../../examples/coding)  
**Requires:** `DEEPSEEK_API_KEY`

## What you will learn

- Scripted vs agentic workflows
- `project.json` `exec` policy (fail-closed)
- `builtin/llm-agent` with filesystem and exec tools
- How the model drives the repair loop

## 1. API key

The coding example uses **DeepSeek** (`deepseek-v4-flash`). Set the key via one of:

1. Copy [`examples/coding/.env.example`](../../examples/coding/.env.example) to
   `examples/coding/.env`
2. `--env-file` on the CLI
3. `$XDG_CONFIG_HOME/hwfi/.env`
4. `export DEEPSEEK_API_KEY=...` in your shell

Verify:

```bash
cabal run hwfi -- check examples/coding
```

## 2. Scripted pipeline first (no LLM)

The default entrypoint `workflows/render` is a **deterministic** mutation +
exec pipeline — useful to see workspace and trace behaviour before involving
the model.

```bash
cp -r examples/coding/sample-workspace /tmp/coding-ws

cabal run hwfi -- run examples/coding \
  --workspace /tmp/coding-ws \
  --input name="Ada"
```

Expected output:

```json
{"exit_code":0,"greeting":"Hello, Ada!\n"}
```

What happened:

1. `builtin/edit-file` replaced `PLACEHOLDER` in `hello.sh`
2. `builtin/exec` ran `sh hello.sh` under the allowlisted policy

The `exec` block in [`project.json`](../../examples/coding/project.json) is
**fail-closed** — without it, `builtin/exec` is rejected at check time:

```json
"exec": {
  "allow": ["sh"],
  "env": ["PATH"],
  "timeout_ms": 10000,
  "max_output_bytes": 65536
}
```

Only basenames in `allow` run; provider API keys are never passed to child
processes unless explicitly listed in `exec.env` (discouraged).

## 3. Agentic repair loop

The `workflows/fix` entrypoint advertises tools to the model:

- `builtin/read-file`, `builtin/grep`, `builtin/edit-file`, `builtin/exec`

The sample workspace includes `broken.sh` — a shell script with a missing `fi`.

```bash
cp -r examples/coding/sample-workspace /tmp/coding-ws

cabal run hwfi -- run examples/coding \
  --workspace /tmp/coding-ws \
  --entry workflows/fix \
  --input target=broken.sh
```

Confirm the fix outside hwfi:

```bash
sh -n /tmp/coding-ws/broken.sh && echo "syntax OK"
```

The agent step is a **non-cacheable black box** at the workflow level, but each
model round and tool call inside it has its own sub-key. See
[caching-and-resume.md](../caching-and-resume.md) and
[Tutorial 4](04-show-resume.md).

## 4. Read the agent workflow

Open [`examples/coding/workflows/fix.md`](../../examples/coding/workflows/fix.md):

- `## agent` — system prompt (`@self#agent`)
- Tool list in the `builtin/llm-agent(...)` call
- `max_rounds` caps the loop
- Outputs include `answer` (final model text) and `rounds` (iteration count)

Non-zero `exit_code` from `exec` is a **value**, not a run error — the agent
can read stderr/stdout and try again.

## 5. Optional — LLM pipeline

Before or after this tutorial, try [`examples/summarise`](../../examples/summarise)
for a linear `read-file` → `llm-generate` → `write-file` pipeline without an
agent loop. See [`examples/summarise/README.md`](../../examples/summarise/README.md).

## Next

- [Tutorial 4: Show and resume](04-show-resume.md) — traces, snapshot resume
- [tool-use.md](../tool-use.md) — design rationale for agent tool loops
