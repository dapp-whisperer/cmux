#!/usr/bin/env bash
set -euo pipefail

INSTALL=0
INSTALL_PATH="/Applications/cmux.app"
BACKUP_PATH="/Applications/cmux.downloaded.app"
LAUNCH=1
INSTALL_CLI=1
CLI_LINK_PATH="/usr/local/bin/cmux"

usage() {
  cat <<'EOF'
Usage: ./scripts/reloadp.sh [options]

Options:
  --install              Install the source-built Release app to /Applications/cmux.app.
                         If an existing app is present there, it is backed up once to
                         /Applications/cmux.downloaded.app and then replaced.
                         Also refreshes the PATH CLI symlink unless --no-install-cli
                         is passed.
  --install-path <path>  Override the install destination used by --install.
  --backup-path <path>   Override the backup destination used by --install.
  --cli-link-path <path> Override the CLI symlink destination used by --install.
  --no-install-cli       Skip updating the PATH CLI symlink during --install.
  --no-launch            Build (and optionally install) without opening the app.
  -h, --help             Show this help.
EOF
}

shell_quote() {
  printf '%q' "$1"
}

run_privileged_shell_command() {
  local command="$1"

  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'do shell script (item 1 of argv) with administrator privileges' \
    -e 'end run' \
    "$command"
}

install_app_bundle() {
  local source_app="$1"
  local install_app="$2"
  local backup_app="$3"
  local info_plist="$install_app/Contents/Info.plist"
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

  mkdir -p "$(dirname "$install_app")"

  if [[ -e "$install_app" || -L "$install_app" ]]; then
    if [[ ! -e "$backup_app" && ! -L "$backup_app" ]]; then
      mv "$install_app" "$backup_app"
      echo "Backed up existing app:"
      echo "  ${backup_app}"
    else
      rm -rf "$install_app"
    fi
  fi

  cp -R "$source_app" "$install_app"

  if [[ -f "$info_plist" ]]; then
    /usr/libexec/PlistBuddy -c "Delete :CMUXSourceBuildInstall" "$info_plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CMUXSourceBuildInstall string 1" "$info_plist" >/dev/null 2>&1 || true
  fi

  /usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$install_app" >/dev/null 2>&1 || true
  if [[ -x "$lsregister" ]]; then
    "$lsregister" -f "$install_app" >/dev/null 2>&1 || true
  fi
}

verify_symlink_target() {
  local expected_path="$1"
  local symlink_path="$2"
  local actual_path=""

  if [[ ! -L "$symlink_path" ]]; then
    echo "error: expected a symlink at $symlink_path" >&2
    exit 1
  fi

  actual_path="$(readlink "$symlink_path" 2>/dev/null || true)"
  if [[ "$actual_path" != "$expected_path" ]]; then
    echo "error: CLI symlink verification failed" >&2
    echo "  expected: ${symlink_path} -> ${expected_path}" >&2
    echo "  actual:   ${symlink_path} -> ${actual_path:-<missing>}" >&2
    exit 1
  fi
}

install_cli_symlink() {
  local source_cli="$1"
  local destination_cli="$2"
  local destination_parent
  local install_command=""

  if [[ ! -x "$source_cli" ]]; then
    echo "error: bundled CLI not found at $source_cli" >&2
    exit 1
  fi

  if [[ -d "$destination_cli" && ! -L "$destination_cli" ]]; then
    echo "error: CLI destination is a directory: $destination_cli" >&2
    exit 1
  fi

  destination_parent="$(dirname "$destination_cli")"
  install_command="/bin/mkdir -p $(shell_quote "$destination_parent") && "
  install_command+="/bin/rm -f $(shell_quote "$destination_cli") && "
  install_command+="/bin/ln -s $(shell_quote "$source_cli") $(shell_quote "$destination_cli")"

  if ! {
    mkdir -p "$destination_parent" 2>/dev/null &&
    rm -f "$destination_cli" 2>/dev/null &&
    ln -s "$source_cli" "$destination_cli" 2>/dev/null
  }; then
    run_privileged_shell_command "$install_command"
  fi

  verify_symlink_target "$source_cli" "$destination_cli"

  echo "Installed CLI symlink:"
  echo "  ${destination_cli} -> ${source_cli}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      INSTALL=1
      shift
      ;;
    --install-path)
      INSTALL_PATH="${2:-}"
      if [[ -z "$INSTALL_PATH" ]]; then
        echo "error: --install-path requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --backup-path)
      BACKUP_PATH="${2:-}"
      if [[ -z "$BACKUP_PATH" ]]; then
        echo "error: --backup-path requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --cli-link-path)
      CLI_LINK_PATH="${2:-}"
      if [[ -z "$CLI_LINK_PATH" ]]; then
        echo "error: --cli-link-path requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --no-install-cli)
      INSTALL_CLI=0
      shift
      ;;
    --no-launch)
      LAUNCH=0
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

xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Release -destination 'platform=macOS' build
pkill -x cmux || true
sleep 0.2

APP_PATH="$(
  find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/cmux.app" -print0 \
  | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
  | sort -nr \
  | head -n 1 \
  | cut -d' ' -f2-
)"
if [[ -z "${APP_PATH}" ]]; then
  echo "cmux.app not found in DerivedData" >&2
  exit 1
fi

echo "Release app:"
echo "  ${APP_PATH}"

if [[ "$INSTALL" -eq 1 ]]; then
  install_app_bundle "$APP_PATH" "$INSTALL_PATH" "$BACKUP_PATH"
  APP_PATH="$INSTALL_PATH"
  echo "Installed source-built app:"
  echo "  ${APP_PATH}"
fi

CLI_PATH="${APP_PATH}/Contents/Resources/bin/cmux"
if [[ -x "$CLI_PATH" ]]; then
  (umask 077; printf '%s\n' "$CLI_PATH" > /tmp/cmux-last-cli-path) || true
  ln -sfn "$CLI_PATH" /tmp/cmux-cli || true
fi

if [[ "$INSTALL" -eq 1 && "$INSTALL_CLI" -eq 1 ]]; then
  install_cli_symlink "$CLI_PATH" "$CLI_LINK_PATH"
fi

if [[ "$LAUNCH" -eq 0 ]]; then
  exit 0
fi

# Dev shells (including CI/Codex) often force-disable paging by exporting these.
# Don't leak that into cmux, otherwise `git diff` won't page even with PAGER=less.
env -u GIT_PAGER -u GH_PAGER open -g "$APP_PATH"

APP_PROCESS_PATH="${APP_PATH}/Contents/MacOS/cmux"
ATTEMPT=0
MAX_ATTEMPTS=20
while [[ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]]; do
  if pgrep -f "$APP_PROCESS_PATH" >/dev/null 2>&1; then
    echo "Release launch status:"
    echo "  running: ${APP_PROCESS_PATH}"
    exit 0
  fi
  ATTEMPT=$((ATTEMPT + 1))
  sleep 0.25
done

echo "warning: Release app launch was requested, but no running process was observed for:" >&2
echo "  ${APP_PROCESS_PATH}" >&2
