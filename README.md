# hwfi

A command-line workflow engine: projects are **markdown + JSON**, type-checked
before run, executed in a sandboxed workspace with **durable traces and resume**.

> **Version 0.1.0.0 (first release).** The [tutorials](docs/tutorials/README.md)
> core path is `examples/hello` and `examples/coding/fix`. Some examples —
> notably [`examples/ship`](examples/ship) — are experimental reference
> orchestrations (check-only in the test suite; live runs are costly and
> non-deterministic).

## Features

- Static type-checking (`hwfi check`) before any execution
- Workflows, tools, type aliases, and optional `skills/` (callable or
  instruction; runtime discover/load — §6.7)
- LLM steps (`llm-generate`, `llm-chat`, `llm-gen-object`) and agent loops
  (`llm-agent`, `llm-agent-object`)
- Sandboxed file I/O, mutation tools, and allowlisted `exec`
- Control flow: `if`/`else`, `foreach`, `par`, `while`, `try`/`catch`
- Machine snapshot resume via `hwfi continue` / `hwfi step`
- Cross-run trace reading and skill extraction (Mode A)
- Agent skill discovery and loading (`discover-skills`, `load-skill`) — §6.7

## Prerequisites

- GHC 9.x (GHC2021)
- **[llm-simple](https://hackage.haskell.org/package/llm-simple-0.1.0.1)**
  `^>=0.1.0.1` — resolved from Hackage by Cabal. All LLM provider calls
  (`llm-generate`, `llm-chat`, `llm-agent`, …) go through `llm-simple`.
- For hosted providers: API keys via project `.env`, `--env-file`, or
  `$XDG_CONFIG_HOME/hwfi/.env` (tutorial examples use **DeepSeek**;
  see each example's `.env.example`)

## Build

```bash
cd /path/to/hwfi
cabal build
cabal test
```

Live example E2E tests in `cabal test` need `DEEPSEEK_API_KEY` for LLM examples
(`summarise`, `coding/fix`); `hello` always runs.

## Quick start

New to hwfi? Start with the [tutorials](docs/tutorials/README.md) — tutorial 1
runs with **no API key**.

```bash
mkdir -p /tmp/hello-ws
echo "World." > /tmp/hello-ws/input.txt

cabal run hwfi -- check examples/hello
cabal run hwfi -- run examples/hello \
  --workspace /tmp/hello-ws \
  --input path=input.txt \
  --input out=greeting.txt
```

For a linear LLM pipeline (optional branch), see
[`examples/summarise`](examples/summarise) (requires `DEEPSEEK_API_KEY`; see
`.env.example`).

After the tutorials, see [`examples/ship`](examples/ship) for a full
plan → build → review orchestration (**experimental** — see that README before
running).

## CLI

```bash
hwfi check <project-dir>
hwfi run <project-dir> --workspace <dir> [--input K=V]... [--entry <qname>]
hwfi continue <workspace-dir> <run-id>
hwfi show <workspace-dir> <run-id>
```

## Examples

### Tutorials (core path)

| Example | Purpose |
|---------|---------|
| [`examples/hello`](examples/hello) | Tutorials 1–2: read → concat → write (no LLM) |
| [`examples/coding`](examples/coding) | Tutorials 3–4: agent loop + `exec` (`workflows/fix`) |

Live E2E for both is in `cabal test` (`hello` always; `coding/fix` with
`DEEPSEEK_API_KEY`).

### Hardened optional

| Example | Purpose |
|---------|---------|
| [`examples/summarise`](examples/summarise) | LLM pipeline: read → generate → write (live E2E with API key) |

### Advanced reference

| Example | Purpose |
|---------|---------|
| [`examples/control-flow`](examples/control-flow) | `if` / `foreach` / `par` / `while` |
| [`examples/research`](examples/research) | Full feature matrix |
| [`examples/workflow-refs`](examples/workflow-refs) | `ToolRef` / `WorkflowRef` patterns (no LLM) |
| [`examples/skills`](examples/skills) | Trace → skill extraction |
| [`examples/skills-runtime`](examples/skills-runtime) | Discover/load skills in an agent loop |

### Experimental

| Example | Purpose |
|---------|---------|
| [`examples/ship`](examples/ship) | Universal coding agent (plan → build → review); check-only in test suite |
| [`examples/webapp`](examples/webapp) | Single-agent HTML builder from a prompt; Ollama by default; not in test suite |

## Documentation

- [docs/tutorials/README.md](docs/tutorials/README.md) — learning path (hello → check → agent → show/resume)
- [docs/workflow-reference.md](docs/workflow-reference.md) — author reference (write and run workflows)
- [docs/spec.md](docs/spec.md) — normative specification
- [docs/workflow-refs.md](docs/workflow-refs.md) — `ToolRef` / `WorkflowRef` patterns
- [docs/caching-and-resume.md](docs/caching-and-resume.md) — resume semantics for authors
- [CHANGELOG.md](CHANGELOG.md) — release history
- [docs/TASKS.md](docs/TASKS.md) — active backlog
- [docs/STATUS.md](docs/STATUS.md) — current focus

## Remaining limitations

See spec §13 and [docs/TASKS.md](docs/TASKS.md). Notable gaps:

- No `Optional<T>` — whitelisted env vars are required at startup
- `Bytes`-typed file I/O and `trace.jsonl` rotation (v1.1 backlog)
- Step-keys classify cacheability at check time; resume uses `machine.json`

For `ToolRef`/`WorkflowRef` patterns and scoping rules, see
[docs/workflow-refs.md](docs/workflow-refs.md).

## License

BSD-3-Clause — see `hwfi.cabal`.
