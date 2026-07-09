# `summarise` — minimal two-step pipeline

The smallest useful workflow: read a text file, summarise it with an LLM, write
the result. Use this as **tutorial 1** before `examples/coding`.

## What it does

1. `builtin/read-file` loads `inputs.path`
2. `builtin/llm-generate` summarises the text (`@self#system` prompt)
3. `builtin/write-file` writes to `inputs.out`

## Prerequisites

Local **Ollama** with the catalog model:

```bash
ollama pull llama3.2:latest   # catalog entry "default"
```

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

- [`../coding`](../coding) — agent loop with `exec` and resume
- [Caching and resume](../../docs/caching-and-resume.md) — how step cache works
