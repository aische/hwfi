# Status

Last updated: 2026-07-13

## Current focus

**v2 runtime (cursor + frames)** — explicit pause/step, snapshot resume, real
`par` with cooperative confirm. Design: [execution-model.md](execution-model.md);
tasks in [TASKS.md](TASKS.md) § v2.

Legacy v1.1 cache-as-resume runtime remains default until M4 cutover.

## Done recently

- **Execution model spec** — [execution-model.md](execution-model.md): transition
  unit, `Machine`/`FrPar`, confirm policy, migration phases M0–M6.
- **M0 done** — `Machine`, `MachinePath`, `MachineSnapshot`, `StepDriver` stub; `MachineSpec` (6 tests).

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) → **M1** sequential `stepMachine`. v1.1 backlog paused until v2 M4.
