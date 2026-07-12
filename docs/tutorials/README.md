# Tutorials

Hands-on guides for learning hwfi. Each tutorial is short (10–20 minutes),
outcome-driven, and links to the [workflow author reference](../workflow-reference.md)
for detail.

## Learning path

| # | Tutorial | Example | API key |
|---|----------|---------|---------|
| 1 | [Hello](01-hello.md) | [`examples/hello`](../../examples/hello) | No |
| 2 | [Check](02-check.md) | same project | No |
| 3 | [Agent](03-agent.md) | [`examples/coding`](../../examples/coding) | Yes |
| 4 | [Show and resume](04-show-resume.md) | [`examples/coding`](../../examples/coding) | Optional |

**Optional next steps** (not part of the core path):

| Example | Topic |
|---------|-------|
| [`examples/summarise`](../../examples/summarise) | LLM pipeline (`read` → `llm-generate` → `write`); live E2E in `cabal test` with API key |
| [`examples/control-flow`](../../examples/control-flow) | `if` / `foreach` / `par` / `while` |
| [`examples/research`](../../examples/research) | Full feature tour |
| [`examples/workflow-refs`](../../examples/workflow-refs) | `ToolRef` / `WorkflowRef` patterns (no LLM) |
| [`examples/skills-runtime`](../../examples/skills-runtime) | Discover/load skills in an agent loop |
| [`examples/ship`](../../examples/ship) | Plan → build → review orchestration (**experimental**) |

## Prerequisites

- GHC 9.x and **[llm-simple](https://hackage.haskell.org/package/llm-simple-0.1.0.1)**
  `^>=0.1.0.1` from Hackage — see root [README.md](../../README.md#prerequisites)
- Built `hwfi` from this repo (`cabal build`)
- For tutorials 3–4: `DEEPSEEK_API_KEY` (see each example's `.env.example`)

## Conventions

- Use a **scratch workspace** under `/tmp/` — never run against the repo tree.
- Run `hwfi check` before `hwfi run` — the checker is your compile step.
- Normative detail lives in [spec.md](../spec.md); cache semantics in
  [caching-and-resume.md](../caching-and-resume.md).
