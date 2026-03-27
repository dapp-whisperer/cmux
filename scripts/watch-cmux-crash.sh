#!/usr/bin/env bash
set -euo pipefail

APP_PREFIX="${1:-cmux}"
TIMEOUT_SECONDS="${CMUX_CRASH_WATCH_TIMEOUT:-180}"
REPORTS_DIR="$HOME/Library/Logs/DiagnosticReports"
CRASH_BREADCRUMBS="/tmp/cmux-workspace-crash-breadcrumbs.log"
LAST_CRASH_BREADCRUMBS="/tmp/cmux-last-workspace-crash-log-path"
ARTIFACTS_DIR="/tmp/cmux-crash-watch-$(date +%Y%m%d-%H%M%S)"
UNIFIED_LOG="$ARTIFACTS_DIR/unified.log"
SUMMARY_FILE="$ARTIFACTS_DIR/summary.txt"
LOG_STREAM_PID=""

mkdir -p "$ARTIFACTS_DIR"

cleanup() {
  if [[ -n "$LOG_STREAM_PID" ]]; then
    kill "$LOG_STREAM_PID" >/dev/null 2>&1 || true
    wait "$LOG_STREAM_PID" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

rm -f "$CRASH_BREADCRUMBS" "$LAST_CRASH_BREADCRUMBS"

BEFORE_LIST_FILE="$ARTIFACTS_DIR/reports-before.txt"
AFTER_LIST_FILE="$ARTIFACTS_DIR/reports-after.txt"

find "$REPORTS_DIR" -maxdepth 1 -type f -name "${APP_PREFIX}*" -print | sort > "$BEFORE_LIST_FILE"

log stream \
  --style compact \
  --predicate 'process == "cmux"' \
  > "$UNIFIED_LOG" 2>&1 &
LOG_STREAM_PID="$!"

echo "artifact_dir=$ARTIFACTS_DIR" > "$SUMMARY_FILE"
echo "app_prefix=$APP_PREFIX" >> "$SUMMARY_FILE"
echo "reports_dir=$REPORTS_DIR" >> "$SUMMARY_FILE"
echo "breadcrumbs=$CRASH_BREADCRUMBS" >> "$SUMMARY_FILE"
echo "timeout_seconds=$TIMEOUT_SECONDS" >> "$SUMMARY_FILE"

echo
echo "Watching for a new ${APP_PREFIX} crash report for up to ${TIMEOUT_SECONDS}s..."
echo "Artifacts:"
echo "  $ARTIFACTS_DIR"
echo
echo "Reproduce the crash now."

deadline=$((SECONDS + TIMEOUT_SECONDS))
LATEST_NEW_REPORT=""

while (( SECONDS < deadline )); do
  find "$REPORTS_DIR" -maxdepth 1 -type f -name "${APP_PREFIX}*" -print | sort > "$AFTER_LIST_FILE"
  LATEST_NEW_REPORT="$(comm -13 "$BEFORE_LIST_FILE" "$AFTER_LIST_FILE" | tail -n 1 || true)"
  if [[ -n "$LATEST_NEW_REPORT" ]]; then
    break
  fi
  sleep 1
done

if [[ -f "$CRASH_BREADCRUMBS" ]]; then
  cp "$CRASH_BREADCRUMBS" "$ARTIFACTS_DIR/"
fi

if [[ -n "$LATEST_NEW_REPORT" ]]; then
  cp "$LATEST_NEW_REPORT" "$ARTIFACTS_DIR/"
  echo "latest_report=$LATEST_NEW_REPORT" >> "$SUMMARY_FILE"
  echo "status=captured" >> "$SUMMARY_FILE"
  echo
  echo "Captured crash artifacts:"
  echo "  $ARTIFACTS_DIR"
  exit 0
fi

echo "status=timeout" >> "$SUMMARY_FILE"
echo
echo "No new crash report appeared before timeout."
echo "Artifacts:"
echo "  $ARTIFACTS_DIR"
exit 1
