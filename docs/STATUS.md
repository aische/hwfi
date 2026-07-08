# Status

Last updated: 2026-07-08

## Current focus

**§9.7 user-level key store shipped.** `$XDG_CONFIG_HOME/hwfi/.env` is now
the lowest-precedence provider-key source (below process env). 235 tests green.

## Done recently

- **9.7:** user config `.env` via `getXdgDirectory`; precedence tests; spec §7.2
  + `CatalogMissingKey` message updated.
- **9.8:** usage/cost accounting (`RunUsage`, `Usage`, budget gate, `hwfi show`).
- **H1** runtime hardening complete (2026-07-08).
- **M8** control flow complete (2026-07-08).

## Blockers

- None.

## Next up

[TASKS.md](TASKS.md) → optional items (8.g, 9.1–9.6).
