#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="JBench"
BUNDLE_ID="com.joshsaintjacque.JBench"
MIN_SYSTEM_VERSION="26.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_BINARY="$APP_MACOS/$APP_NAME"
PROCESS_LAUNCHER="$APP_HELPERS/JBenchProcessLauncher"
INFO_PLIST="$APP_CONTENTS/Info.plist"

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"
BUILD_PROCESS_LAUNCHER="$(swift build --show-bin-path)/JBenchProcessLauncher"

if [[ "$APP_BUNDLE" != "$DIST_DIR/$APP_NAME.app" ]]; then
  echo "refusing unexpected app bundle path: $APP_BUNDLE" >&2
  exit 1
fi
if [[ -e "$APP_BUNDLE" ]]; then
  rm -r "$APP_BUNDLE"
fi
mkdir -p "$APP_MACOS" "$APP_HELPERS"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_PROCESS_LAUNCHER" "$PROCESS_LAUNCHER"
chmod +x "$APP_BINARY"
chmod +x "$PROCESS_LAUNCHER"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() { /usr/bin/open -n "$APP_BUNDLE"; }

verify_app() {
  local verify_log="$DIST_DIR/verify.log"
  "$APP_BINARY" >"$verify_log" 2>&1 &
  local app_pid=$!
  cleanup_verify() {
    if kill -0 "$app_pid" >/dev/null 2>&1; then
      kill -TERM "$app_pid" >/dev/null 2>&1 || true
      wait "$app_pid" 2>/dev/null || true
    fi
  }
  trap cleanup_verify EXIT INT TERM
  for _ in {1..30}; do
    if kill -0 "$app_pid" >/dev/null 2>&1; then
      sleep 0.1
    else
      echo "JBench exited during launch verification. See $verify_log" >&2
      return 1
    fi
  done
  cleanup_verify
  trap - EXIT INT TERM
}

case "$MODE" in
  run) open_app ;;
  --debug|debug) lldb -- "$APP_BINARY" ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    verify_app
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
