# skills-runtime

Minimal project demonstrating the §6.7 skill toolbox: instruction and callable
skills under `skills/`, plus `builtin/discover-skills` and `builtin/load-skill`
on an agent step.

## Check

```bash
hwfi check examples/skills-runtime
```

## Dry run

With provider keys configured for your catalog:

```bash
hwfi run examples/skills-runtime --workspace /tmp/skills-runtime-ws \
  --input task="Find shell repair guidance and fix scripts"
```

The agent advertises the meta-tools explicitly in its `tools` list. Inside the
loop, `load-skill` can inject instruction bodies or expand callable skills into
the active tool set (see `docs/skills-design.md`).
