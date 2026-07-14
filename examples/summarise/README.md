# `summarise` — minimal two-step pipeline

The smallest useful **LLM** workflow: read a text file, summarise it with an
LLM, write the result. For the core learning path start with
[docs/tutorials/README.md](../../docs/tutorials/README.md) (`examples/hello` →
`examples/coding`). Use this example as an **optional** linear LLM branch; it
has live E2E coverage in `cabal test` when `DEEPSEEK_API_KEY` is set.

## What it does

1. `builtin/read-file` loads `inputs.path`
2. `builtin/llm-generate` summarises the text (`@self#system` prompt)
3. `builtin/write-file` writes to `inputs.out`

## Prerequisites

**DeepSeek API** with catalog model `deepseek-v4-flash` (catalog entry `default`).
Set `DEEPSEEK_API_KEY` via one of:

1. `examples/summarise/.env` — copy from [`.env.example`](.env.example)
2. `--env-file` on the CLI
3. `$XDG_CONFIG_HOME/hwfi/.env`
4. Export in your shell: `export DEEPSEEK_API_KEY=...`

## Running

```bash
mkdir -p /tmp/summarise-ws
echo "The quick brown fox jumps over the lazy dog. This sentence is often used for typing practice." \
  > /tmp/summarise-ws/article.txt

cabal run hwfi -- check examples/summarise

cabal run hwfi -- run examples/summarise \
  --workspace /tmp/summarise-ws \
  --input path=article.txt \
  --input out=summary.txt
```

On success, output JSON includes `summary` and `summary.txt` exists in the workspace.

## Inspect

```bash
cabal run hwfi -- show /tmp/summarise-ws <run-id>
```

## Next steps

- [Tutorials](../../docs/tutorials/README.md) — hello → check → agent → show/resume
- [`../coding`](../coding) — agent loop with `exec` and resume
- [Caching and resume](../../docs/caching-and-resume.md) — snapshot resume semantics
