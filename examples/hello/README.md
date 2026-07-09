# `hello` — minimal file pipeline (no LLM)

The smallest runnable project: read a text file, prepend a banner, call a
sub-workflow, write the output. Use this as the starting point for
[docs/tutorials/01-hello.md](../../docs/tutorials/01-hello.md).

## What it does

1. `builtin/read-file` loads `inputs.path`
2. `builtin/concat` prepends the `@self#banner` section
3. `workflows/inner` writes `inner.txt` (sub-workflow call)
4. `builtin/write-file` writes to `inputs.out` and `banner.txt`

## Prerequisites

None — no API keys or network access required.

## Running

```bash
mkdir -p /tmp/hello-ws
echo "World." > /tmp/hello-ws/input.txt

cabal run hwfi -- check examples/hello

cabal run hwfi -- run examples/hello \
  --workspace /tmp/hello-ws \
  --input path=input.txt \
  --input out=greeting.txt
```

On success, output JSON includes `greeting` and `greeting.txt` exists in the
workspace.

## Inspect

```bash
cabal run hwfi -- show /tmp/hello-ws <run-id>
```

## Next steps

- [Tutorial 2: Check](../../docs/tutorials/02-check.md) — type-check errors
- [Tutorial 3: Agent](../../docs/tutorials/03-agent.md) — `examples/coding`
