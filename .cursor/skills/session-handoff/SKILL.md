---
name: session-handoff
description: >-
  End-of-session handoff for this project. Updates STATUS and TASKS, archives
  completed work, and appends decision log entries. Use when the user says
  handoff, wrap up, end session, update docs, or save progress.
---

# Session handoff

Run this at the end of a coding session or when the user asks to save progress.

## Steps

1. **Review what changed**
   - Scan git diff and recent commits (if any)
   - Identify decisions made, blockers resolved, and tasks completed

2. **Update `docs/STATUS.md`**
   - Set "Last updated" to today's date
   - Rewrite "Current focus", "Done recently", "Blockers", "Next up"
   - Keep the file under 80 lines

3. **Update `docs/TASKS.md`**
   - Check off completed items in **Now**
   - Promote items from **Next** to **Now** if appropriate
   - Move completed items from **Done** to `docs/log/archive/tasks-YYYY-MM.md` if the Done section is getting long

4. **Log decisions (optional)**
   - Append to `docs/log/YYYY-MM.md` only if a design decision, blocker resolution, or milestone occurred
   - Format: `## YYYY-MM-DD — Short title` then bullet points

5. **Summarize for the user**
   - 3–5 bullets: what was done, what's next, any open blockers

## Do not

- Copy chat prompts into the log
- List every file changed (git covers that)
- Grow `TASKS.md` with archived completed work
