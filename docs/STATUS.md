# Status

Last updated: 2026-07-13

## Current focus

**v2 runtime (cursor + frames)** — M3 `par` + cooperative confirm done. Next: M4 CLI
`step` / `continue` cutover. Design: [execution-model.md](execution-model.md).

Legacy v1.1 cache-as-resume runtime remains default until M4 cutover.

## Done recently

- **M3 done** — real `par` in `StepDriver` (`FrPar`, `CurParPool`, `MachinePar`);
  bounded concurrent branch stepping (`stepParWave`); cooperative exec-confirm drain
  inside `par`; per-branch snapshots in `pjsActive`; `MachineSpec` par e2e + resume +
  confirm.
- **M2** — agent `CurAgent` stepping; `MachineAgent`; snapshot resume.
- **M1** — sequential `stepMachine`, control flow, `StepEnv`, `runMachine`.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) → **M4** CLI `step` / `continue`; replace `performResume`.
