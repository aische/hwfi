# Status

Last updated: 2026-07-13

## Current focus

**v2 runtime (cursor + frames)** — M2 agent `CurAgent` stepping done. Next: M3 real
`par` + cooperative confirm. Design: [execution-model.md](execution-model.md).

Legacy v1.1 cache-as-resume runtime remains default until M4 cutover.

## Done recently

- **M2 done** — `CurAgent` transitions in `stepMachine` (one model call or one tool
  call per step); `MachineAgent`; agent state in machine snapshot (no intra-step
  sub-key replay on v2 path); `MachineSpec` agent e2e + snapshot resume.
- **M1** — sequential `stepMachine`, control flow, `StepEnv`, `runMachine`.
- **M0** — `Machine`, `MachinePath`, `MachineSnapshot`, frame types.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) → **M3** real `par` + cooperative confirm + branch snapshots.
