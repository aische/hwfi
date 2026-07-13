# Status

Last updated: 2026-07-13

## Current focus

**v2 runtime (cursor + frames)** — M1 sequential `stepMachine` done. Next: M2 agent
`Current` states. Design: [execution-model.md](execution-model.md).

Legacy v1.1 cache-as-resume runtime remains default until M4 cutover.

## Done recently

- **M1 done** — `stepMachine` for sequential steps, builtins, sub-workflows,
  `if`/`foreach`/`while`/`try`; `StepEnv`; `runMachine`; `MachineSpec` e2e
  (file-only fixture).
- **M0** — `Machine`, `MachinePath`, `MachineSnapshot`, frame types; snapshot JSON.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) → **M2** agent `Current` states; drop agent sub-key replay.
