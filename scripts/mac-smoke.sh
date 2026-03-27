#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_KIND="debug"
SCENARIO="titlebar-new-workspace"
TAG="local-smoke"
ARTIFACTS_DIR=""
REINSTALL_RELEASE=0

usage() {
  cat <<'EOF'
Usage: ./scripts/mac-smoke.sh [options]

Options:
  --app debug|release      App variant to smoke (default: debug)
  --scenario <name>        Smoke scenario (default: titlebar-new-workspace)
  --tag <name>             Tagged debug build name (default: local-smoke)
  --artifacts-dir <path>   Directory for screenshots/report output
  --reinstall-release      Rebuild and reinstall /Applications/cmux.app before smoke
  -h, --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_KIND="${2:-}"
      shift 2
      ;;
    --scenario)
      SCENARIO="${2:-}"
      shift 2
      ;;
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    --artifacts-dir)
      ARTIFACTS_DIR="${2:-}"
      shift 2
      ;;
    --reinstall-release)
      REINSTALL_RELEASE=1
      shift
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

if [[ "$APP_KIND" != "debug" && "$APP_KIND" != "release" ]]; then
  echo "error: --app must be debug or release" >&2
  exit 1
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
if [[ -z "$ARTIFACTS_DIR" ]]; then
  ARTIFACTS_DIR="/tmp/cmux-smoke/${APP_KIND}-${SCENARIO}-${timestamp}"
fi
mkdir -p "$ARTIFACTS_DIR"

APP_PATH=""

if [[ "$APP_KIND" == "debug" ]]; then
  echo "== build tagged debug =="
  BUILD_OUTPUT="$(./scripts/reload.sh --tag "$TAG")"
  printf '%s\n' "$BUILD_OUTPUT"
  APP_PATH="$(printf '%s\n' "$BUILD_OUTPUT" | sed -n '/^App path:/{n;s/^[[:space:]]*//;p;q;}')"
  if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    echo "error: failed to determine debug app path from reload.sh output" >&2
    exit 1
  fi
else
  if [[ "$REINSTALL_RELEASE" -eq 1 ]]; then
    echo "== rebuild/install release =="
    ./scripts/reloadp.sh --install --no-launch
  fi
  APP_PATH="/Applications/cmux.app"
  if [[ ! -d "$APP_PATH" ]]; then
    echo "error: release app not found at $APP_PATH" >&2
    exit 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CMUXSourceBuildInstall' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)" != "1" ]]; then
    echo "error: $APP_PATH is not marked as a source-built install; rerun with --reinstall-release" >&2
    exit 1
  fi
fi

printf '%s\n' "app_path=$APP_PATH" > "$ARTIFACTS_DIR/command.txt"
printf '%s\n' "scenario=$SCENARIO" >> "$ARTIFACTS_DIR/command.txt"
printf '%s\n' "app_kind=$APP_KIND" >> "$ARTIFACTS_DIR/command.txt"

swift ./scripts/mac-smoke.swift \
  --app-path "$APP_PATH" \
  --scenario "$SCENARIO" \
  --artifacts-dir "$ARTIFACTS_DIR" \
  --launch

echo
echo "Artifacts:"
echo "  $ARTIFACTS_DIR"
