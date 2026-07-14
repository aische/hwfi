---
kind: type-alias
name: types/finding
definition: "Record<{ severity: String, category: String, location: types/location, claim: String, evidence: String, suggestion: String }>"
---

One semantic review finding emitted into the run's `semantic-report.json`
(`.hwfi/runs/<run-id>/`).
