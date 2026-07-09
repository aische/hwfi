# hwfi

A command-line workflow engine: projects are **markdown + JSON**, type-checked
before run, executed in a sandboxed workspace with **durable traces and resume**.

## Features

- Static type-checking (`hwfi check`) before any execution
- Workflows, tools, type aliases, and optional `skills/` (callable or
  instruction; runtime discover/load — §6.7)
- LLM steps (`llm-generate`, `llm-chat`, `llm-gen-object`) and agent loops
  (`llm-agent`, `llm-agent-object`)
- Sandboxed file I/O, mutation tools, and allowlisted `exec`
- Control flow: `if`/`else`, `foreach`, `par`, `while`
- Content-addressed step cache and `hwfi resume`
- Cross-run trace reading and skill extraction (Mode A)
- Agent skill discovery and loading (`discover-skills`, `load-skill`) — §6.7

## Prerequisites

- GHC 9.x (GHC2021)
- [llm-simple](../llm-simple) as a sibling package (see `cabal.project`)
- For hosted providers: API keys via project `.env`, `--env-file`, or
  `$XDG_CONFIG_HOME/hwfi/.env` (tutorial examples use **DeepSeek**;
  see each example's `.env.example`)

## Build

```bash
cd /path/to/hwfi
cabal build
cabal test
```

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

For an LLM pipeline, see [`examples/summarise`](examples/summarise) (requires
`DEEPSEEK_API_KEY`; see `.env.example`).

## CLI

```bash
hwfi check <project-dir>
hwfi run <project-dir> --workspace <dir> [--input K=V]... [--entry <qname>]
hwfi resume <workspace-dir> <run-id>
hwfi show <workspace-dir> <run-id>
hwfi cache clear <workspace-dir> <run-id>
```

## Examples

| Example | Purpose |
|---------|---------|
| [`examples/hello`](examples/hello) | Tutorial 1: read → concat → write (no LLM) |
| [`examples/summarise`](examples/summarise) | LLM pipeline: read → generate → write |
| [`examples/coding`](examples/coding) | Agent coding loop + `exec` |
| [`examples/control-flow`](examples/control-flow) | `if` / `foreach` / `par` / `while` |
| [`examples/research`](examples/research) | Full feature matrix (advanced) |
| [`examples/ship`](examples/ship) | Universal coding agent (plan → build → review) |
| [`examples/skills`](examples/skills) | Trace → skill extraction |
| [`examples/skills-runtime`](examples/skills-runtime) | Discover/load skills in an agent loop |

## Documentation

- [docs/tutorials/README.md](docs/tutorials/README.md) — learning path (hello → check → agent → show/resume)
- [docs/workflow-reference.md](docs/workflow-reference.md) — author reference (write and run workflows)
- [docs/spec.md](docs/spec.md) — normative specification
- [docs/caching-and-resume.md](docs/caching-and-resume.md) — cache semantics for authors
- [CHANGELOG.md](CHANGELOG.md) — release history
- [docs/TASKS.md](docs/TASKS.md) — active backlog
- [docs/STATUS.md](docs/STATUS.md) — current focus

## v1 limitations

See spec §13 for the v1.1 backlog. Notable gaps:

- No workflow-level `try`/recover (agent tool errors are recoverable)
- No `Optional<T>` — whitelisted env vars are required at startup
- `ToolRef`/`WorkflowRef` dynamic invocation patterns are limited
- Step cache keys do not include workspace file contents

## License

BSD-3-Clause — see `hwfi.cabal`.
