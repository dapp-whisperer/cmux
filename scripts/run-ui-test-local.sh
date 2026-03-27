#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

TEST_FILTER="${1:-MenuKeyEquivalentRoutingUITests/testTitlebarNewWorkspaceButtonCreatesWorkspaceWithoutCrash}"
if [[ $# -gt 0 ]]; then
  shift
fi

ARTIFACTS_DIR=""
DERIVED_DATA_PATH=""
SOURCE_PACKAGES_DIR="$PWD/.ci-source-packages"

usage() {
  cat <<'EOF'
Usage: ./scripts/run-ui-test-local.sh [test_filter] [options]

Arguments:
  test_filter             Class or class/method under cmuxUITests

Options:
  --artifacts-dir <path>  Directory for xcresult/log output
  --derived-data <path>   DerivedData path for the local run
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifacts-dir)
      ARTIFACTS_DIR="${2:-}"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA_PATH="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage
      exit 1
      ;;
  esac
done

timestamp="$(date +%Y%m%d-%H%M%S)"
if [[ -z "$ARTIFACTS_DIR" ]]; then
  ARTIFACTS_DIR="/tmp/cmux-ui-local/${timestamp}"
fi
if [[ -z "$DERIVED_DATA_PATH" ]]; then
  DERIVED_DATA_PATH="/tmp/cmux-ui-local-derived-${timestamp}"
fi

mkdir -p "$ARTIFACTS_DIR" "$SOURCE_PACKAGES_DIR"
LOG_PATH="$ARTIFACTS_DIR/xcodebuild.log"
RESULT_BUNDLE_PATH="$ARTIFACTS_DIR/cmux-ui-local.xcresult"
SUMMARY_PATH="$ARTIFACTS_DIR/summary.json"

echo "== resolve packages =="
for attempt in 1 2 3; do
  if xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
    -resolvePackageDependencies >/dev/null; then
    break
  fi
  if [[ "$attempt" -eq 3 ]]; then
    echo "error: failed to resolve Swift packages after 3 attempts" >&2
    exit 1
  fi
  echo "Package resolution failed on attempt $attempt, retrying..."
  sleep $((attempt * 5))
done

rm -rf "$DERIVED_DATA_PATH" "$RESULT_BUNDLE_PATH"

set +e
xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -configuration Debug \
  -destination "platform=macOS" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -resultBundlePath "$RESULT_BUNDLE_PATH" \
  -only-testing:cmuxUITests/"$TEST_FILTER" \
  test 2>&1 | tee "$LOG_PATH"
status=${PIPESTATUS[0]}
set -e

FAILURE_HINT=""
if [[ "$status" -ne 0 ]]; then
  if rg -q "Timed out while enabling automation mode" "$LOG_PATH"; then
    FAILURE_HINT="XCUITest could not enable macOS automation mode. Re-run after granting Xcode and the test runner the required UI automation permissions, or retry from a fresh logged-in desktop session."
    echo "note: $FAILURE_HINT" >&2
  fi
fi

python3 - <<PY
import json
from pathlib import Path

summary = {
    "testFilter": ${TEST_FILTER@Q},
    "artifactsDir": ${ARTIFACTS_DIR@Q},
    "derivedDataPath": ${DERIVED_DATA_PATH@Q},
    "resultBundlePath": ${RESULT_BUNDLE_PATH@Q},
    "logPath": ${LOG_PATH@Q},
    "status": "passed" if ${status} == 0 else "failed",
    "exitCode": ${status},
    "failureHint": ${FAILURE_HINT@Q},
}
Path(${SUMMARY_PATH@Q}).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\\n")
PY

echo
echo "Artifacts:"
echo "  $ARTIFACTS_DIR"

exit "$status"
