# Tutorial 1: Hello

Run your first hwfi workflow with **no API keys** and no network access.

**Time:** ~10 minutes  
**Example:** [`examples/hello`](../../examples/hello)

## What you will learn

- Project layout (`project.json`, `workflows/`, `model-catalog.json`)
- The step DSL: bindings, imports, `return`
- Builtins: `read-file`, `concat`, `write-file`
- Sub-workflow calls and `@self#` prompt sections

## 1. Set up a workspace

hwfi runs workflows against a **workspace directory** — a folder where the
engine reads and writes files. Keep it outside the repo:

```bash
mkdir -p /tmp/hello-ws
echo "World." > /tmp/hello-ws/input.txt
```

## 2. Type-check the project

Every run starts with static checking. Silence means success:

```bash
cabal run hwfi -- check examples/hello
```

`hwfi check` loads all markdown declarations, resolves imports, and verifies
types before any file I/O or side effects. See [Tutorial 2](02-check.md) for
what happens when check fails.

## 3. Run the workflow

```bash
cabal run hwfi -- run examples/hello \
  --workspace /tmp/hello-ws \
  --input path=input.txt \
  --input out=greeting.txt
```

Expected output (JSON):

```json
{"greeting":"Hello from hwfi.\nWorld.\n"}
```

Verify the workspace:

```bash
cat /tmp/hello-ws/greeting.txt
cat /tmp/hello-ws/inner.txt
cat /tmp/hello-ws/banner.txt
```

## 4. Read the workflow

Open [`examples/hello/workflows/main.md`](../../examples/hello/workflows/main.md).
The structure is the same for every workflow and tool:

| Section | Purpose |
|---------|---------|
| YAML front matter | `name`, typed `inputs`/`outputs`, `imports` |
| Markdown headings | Prompt sections referenced as `@self#heading-slug` |
| `## flow` + ` ```step` block | The program |

The flow block:

```step
c      <- builtin/read-file(path = ${inputs.path})
merged <- builtin/concat(parts = [@self#banner, "\n", ${c.text}]) @merge
_      <- workflows/inner(note = ${c.text}) @inner
_      <- builtin/write-file(path = ${inputs.out}, text = ${merged.text}) @write
_      <- builtin/write-file(path = "banner.txt", text = @self#banner) @banner
return { greeting = ${merged.text} }
```

Notes:

- `${inputs.path}` — workflow input binding
- `@self#banner` — content under the `## banner` heading in this file
- `@merge`, `@inner`, … — step ids (unique within a block); appear in traces
- `_ <- …` — discard a binding when you only need the side effect
- `workflows/inner` — sub-workflow call ([`workflows/inner.md`](../../examples/hello/workflows/inner.md))

## 5. Inspect the run

The CLI prints output JSON; durable state lives under `.hwfi/` in the workspace.
Note the run id from the run output or list the runs directory:

```bash
ls /tmp/hello-ws/.hwfi/runs/
cabal run hwfi -- show /tmp/hello-ws <run-id>
```

You should see trace events for each step: file reads, the sub-workflow call,
and file writes.

## 6. Project files

```
examples/hello/
  project.json           # manifest: name, entrypoint
  model-catalog.json     # required (empty [] when no LLM steps)
  workflows/
    main.md              # entry workflow
    inner.md             # sub-workflow
```

Even projects without LLM calls must ship `model-catalog.json` (it can be an
empty array). See [Project layout](../workflow-reference.md#project-layout) in
the author reference.

## Next

- [Tutorial 2: Check](02-check.md) — break the project on purpose and fix type errors
- [Tutorial 3: Agent](03-agent.md) — LLM agent loop with tools and `exec`
