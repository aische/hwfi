---
name: skills/webapp-html-guide
skill:
  kind: instruction
  summary: Single-file HTML/CSS/JS apps without a bundler
  tags: [html, css, javascript, frontend]
---

# Single-file web app guide

Use for simple demos, calculators, or when the spec does not require npm/Vite.

## Authoring

1. Write `index.html` at the workspace root with inline `<style>` and `<script>`.
2. No external CDN or network requests — keep the app self-contained.
3. Use semantic HTML; keep CSS in a `<style>` block; JS in a `<script>` block.

## Verification

Run via `builtin/exec`:

```
program = "sh"
args = ["-c", "test -s index.html && grep -qi '<html' index.html"]
```

A zero exit means the file exists and looks like HTML.

## UX

- Mobile-friendly viewport meta tag.
- Clear labels on inputs; keyboard-accessible controls.
- Persist to `localStorage` when the spec asks for persistence.
