#!/usr/bin/env bash
# Run semantic-check → semantic-pragmatic → semantic-summary on a workspace.
#
# Usage:
#   scripts/semantic-review.sh <workspace> [entry] [summary-mode]
#
# Examples:
#   scripts/semantic-review.sh examples/ship
#   scripts/semantic-review.sh examples/ship workflows/main mechanical
#
# Requires model catalog for pragmatic (and narrative summary if used).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORKSPACE="${1:?Usage: $0 <workspace> [entry] [summary-mode]}"
ENTRY="${2:-workflows/main}"
SUMMARY_MODE="${3:-mechanical}"
SCHEMA="@examples/semantic-pragmatic/pragmatic-schema.json"

CHECK_LOG="$(mktemp)"
trap 'rm -f "$CHECK_LOG"' EXIT

echo "==> semantic-check (workspace: $WORKSPACE, entry: $ENTRY)"
set +e
cabal run hwfi -- run examples/semantic-check \
  --workspace "$WORKSPACE" \
  --input path=. \
  --input entry="$ENTRY" \
  2>&1 | tee "$CHECK_LOG"
check_exit=${PIPESTATUS[0]}
set -e
if [[ "$check_exit" -ne 0 ]]; then
  exit "$check_exit"
fi

RUN_ID="$(grep -m1 '^run-id: ' "$CHECK_LOG" | sed 's/^run-id: //')"
if [[ -z "$RUN_ID" ]]; then
  echo "error: could not determine run-id from semantic-check output" >&2
  exit 1
fi

echo ""
echo "run-id: $RUN_ID"
echo ""

echo "==> semantic-pragmatic"
cabal run hwfi -- run examples/semantic-pragmatic \
  --workspace "$WORKSPACE" \
  --input source_run="$RUN_ID" \
  --input schema="$SCHEMA"

echo ""
echo "==> semantic-summary (mode: $SUMMARY_MODE)"
cabal run hwfi -- run examples/semantic-summary \
  --workspace "$WORKSPACE" \
  --input source_run="$RUN_ID" \
  --input mode="$SUMMARY_MODE"

echo ""
echo "Done."
echo "  run-id:           $RUN_ID"
echo "  semantic-report:  .hwfi/runs/$RUN_ID/semantic-report.json"
echo "  semantic-summary: .hwfi/runs/$RUN_ID/semantic-summary.md"
