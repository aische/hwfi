# `control-flow` — `if` / `foreach` / `par` example

Demonstrates the M8 control-flow constructs (spec §13) in a single scripted
workflow, `workflows/main`:

- **`par`** — a bounded parallel loop. Syntax-checks every input script with
  `sh -n` concurrently (`max = 4` in flight), returning a result list in **input
  order** regardless of completion order.
- **`foreach`** — an ordered sequential loop. Appends each script name to a
  `manifest.txt`, one iteration at a time; the result list is discarded (`_`), so
  the loop is used purely for its ordered side effects.
- **`if` / `else`** — a value-producing conditional. Both branches bind a step
  result of the same type, so the `if` yields that value.

## Semantics (as implemented)

Control-flow constructs are **value-producing**, uniform with step calls:

- A block's value is the value of its **last statement**; an empty block yields an
  empty record.
- `x <- if ${cond} { … } else { … }` requires `cond : Bool`, an `else` clause, and
  both arms to share a structurally-equal result type.
- `xs <- foreach v in ${list} { … }` / `par …` bind `List<U>`, where `U` is the
  body's tail type and `list : List<T>` binds `v : T` in the body scope.
- `par` runs iterations concurrently (default bound 4, override with `par(max = N)`),
  returns results in **input order**, and aborts on the **lowest-index** failure.
- Scoping is **block-local** (§4.2): the outer scope is visible inside a block,
  inner bindings do not escape, and **no shadowing** of outer names is allowed.
  Step `@id`s must be unique **within a block**; sibling `if` branches and
  unrelated loops may reuse the same `@id` (the runtime disambiguates via the
  scope prefix, e.g. `mode?then/notify` vs `mode?else/notify`). That is
  why the `then`/`else` arms here both bind `msg` with `@notify`.

## Resume behaviour (durable workspace, spec §8)

Each `builtin/exec` inside a loop or branch records progress in `machine.json`.
On resume, completed iterations are not re-run — per-iteration side effects
(like the manifest appends) apply **exactly once** across a run + resume.

The trace records the control flow explicitly: `loop-start`/`loop-iter`/`loop-end`
bracket each loop with its kind (`foreach`/`par`) and count, and `if-branch`
records which arm was taken.

## Running it

```bash
# Use a scratch workspace so run artifacts don't land in the repo:
cp -r examples/control-flow/sample-workspace /tmp/cf-ws

cabal run hwfi -- run examples/control-flow \
  --workspace /tmp/cf-ws \
  --input-json examples/control-flow/inputs.example.json
```

Output (all three scripts are valid, so every `sh -n` exits 0):

```json
{"first_status":0,"report":"STRICT mode: every script must pass\n"}
```

Inspect the trace to see the loops and branch:

```bash
cabal run hwfi -- show /tmp/cf-ws <run-id>
#  1  loop-start  workflows/main#check     par       count=3
#  2  loop-iter   workflows/main#check     #0
#  3  step-start  workflows/main#c         [cacheable]
#  8  exec        workflows/main#c         sh  exit=0
# 14  loop-end    workflows/main#check     count=3
# 15  loop-start  workflows/main#manifest  foreach   count=3
# 18  exec        workflows/main#w         sh  exit=0
# 28  loop-end    workflows/main#manifest  count=3
# 29  if-branch   workflows/main#mode      -> then
# 31  exec        workflows/main#notify  sh  exit=0
```

(The three `par` iterations start before any completes, then interleave; a
`foreach` iteration completes before the next starts.)

Flip `strict` to `false` in the inputs to take the `else` branch, or point
`scripts` at a file with a syntax error to see `par` return a non-zero
`first_status` (a non-zero exit is a *value*, not a run error, spec §6.3).

## Resume

```bash
cabal run hwfi -- continue /tmp/cf-ws <run-id>
```

The manifest still contains exactly three lines and no command is re-run —
completed iterations are reflected in the machine snapshot.

## `while` (predicate/body loop, §4.3)

A second entrypoint demonstrates the `while` construct with external predicate
and body workflows:

```bash
cabal run hwfi -- run examples/control-flow \
  --workspace /tmp/cf-ws \
  --entry workflows/tick-stop
```

Output: `{"done":true}`. The predicate returns `continue = false` on the first
evaluation, so the body never runs. See `workflows/tick-stop.md`,
`workflows/tick-pred.md`, and `workflows/tick-body.md` for the split
predicate/body pattern and required `predicate_args` / `body_args` records.
