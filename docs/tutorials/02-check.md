# Tutorial 2: Check

Treat `hwfi check` as a **compile step**: it catches structural and type errors
before any run side effects.

**Time:** ~10 minutes  
**Example:** [`examples/hello`](../../examples/hello)

## What you will learn

- What `hwfi check` validates
- How checker errors are reported
- Common mistakes and how to fix them

## 1. Baseline — check passes

From [Tutorial 1](01-hello.md), confirm the project still type-checks:

```bash
cabal run hwfi -- check examples/hello
```

Exit code `0` and no output means the whole project is consistent: imports
resolve, types match, exec policy (if any) is satisfied, and prompt section
references exist.

## 2. Break it — missing import

Open [`examples/hello/workflows/main.md`](../../examples/hello/workflows/main.md)
and **remove** `builtin/concat` from the `imports:` list in the front matter.
Leave the `builtin/concat(...)` call in the flow block.

Run check:

```bash
cabal run hwfi -- check examples/hello
```

You should see an error about an undeclared or unknown callee — the checker
does not allow calling a qname you did not import.

**Fix:** restore `builtin/concat` in `imports:` and check again.

## 3. Break it — type mismatch

In the same file, temporarily change the `return` line to:

```step
return { greeting = ${c.text} }
```

Here `c.text` is a `String`, but if you instead bind a `FileRef` where a
`String` is expected in an output field, check fails. A simpler mismatch: change
an input type in the front matter from `FileRef` to `String` while leaving
`builtin/read-file(path = ${inputs.path})` unchanged — `read-file` expects
`FileRef`.

Run check, read the error (it names the workflow, step, and expected vs actual
type), then **revert** your edit.

## 4. Break it — duplicate step id

In one flow block, give two steps the same `@id`:

```step
c <- builtin/read-file(path = ${inputs.path}) @read
_ <- builtin/write-file(path = "x.txt", text = "x") @read
return { greeting = ${c.text} }
```

Check rejects duplicate `@id`s within the same block.

**Fix:** use unique step ids (`@read`, `@write`, …).

## 5. What check does not do

`hwfi check` does **not**:

- Run workflows or call LLMs
- Verify workspace files exist
- Prove your prompts are good

It **does** validate the whole project graph: workflows, tools, types, imports,
cycles, exec allowlists, agent tool lists, and `@self#` section references.
See [spec.md §5](../spec.md) for the full rules.

## 6. Check other examples

The same command works on any project directory:

```bash
cabal run hwfi -- check examples/summarise
cabal run hwfi -- check examples/coding
cabal run hwfi -- check examples/ship
```

Use check in CI or before every run during development.

## Next

- [Tutorial 3: Agent](03-agent.md) — agent loop with `read-file`, `edit-file`, and `exec`
- [Author reference: Workflows and tools](../workflow-reference.md#workflows-and-tools)
