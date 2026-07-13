# Status

Last updated: 2026-07-13

## Current focus

**v2 runtime (cursor + frames)** — M4 CLI cutover done. Finish the v2 tranche:
**M6** (drop legacy cache-as-resume, single resume story, spec §8). Design:
[execution-model.md](execution-model.md).

**M5** (DB / server `ProjectStore`) is deferred — optional, not blocking local
filesystem mode.

Legacy v1.1 cache-as-resume `Executor.performRun` remains for direct test use
until M6.

## Done recently

- **M4** — `MachineRun`, `machine.json`, CLI `continue` / `step` / `resume`.
- **M3** — real `par`, cooperative confirm, per-branch snapshots.
- **M2** — agent `CurAgent` stepping; snapshot resume.
- **M1** — sequential `stepMachine`, control flow, `StepEnv`, `runMachine`.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) → **M6** legacy cutover and resume test migration.
