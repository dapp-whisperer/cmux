#!/usr/bin/env bash
set -euo pipefail

ARTIFACTS_DIR="${1:-/tmp/cmux-crash-capture-$(date +%Y%m%d-%H%M%S)}"
REPORTS_DIR="$HOME/Library/Logs/DiagnosticReports"
CRASH_BREADCRUMBS="/tmp/cmux-workspace-crash-breadcrumbs.log"

mkdir -p "$ARTIFACTS_DIR"

LATEST_REPORT="$(ls -1t "$REPORTS_DIR"/cmux* 2>/dev/null | head -n 1 || true)"
if [[ -z "$LATEST_REPORT" ]]; then
  echo "error: no cmux crash report found in $REPORTS_DIR" >&2
  exit 1
fi

cp "$LATEST_REPORT" "$ARTIFACTS_DIR/"

if [[ -f "$CRASH_BREADCRUMBS" ]]; then
  cp "$CRASH_BREADCRUMBS" "$ARTIFACTS_DIR/"
fi

{
  echo "artifact_dir=$ARTIFACTS_DIR"
  echo "latest_report=$LATEST_REPORT"
  echo "breadcrumbs=$CRASH_BREADCRUMBS"
} > "$ARTIFACTS_DIR/summary.txt"

echo
echo "Captured crash artifacts:"
echo "  $ARTIFACTS_DIR"
