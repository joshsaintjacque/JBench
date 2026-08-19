#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="JBench"
BUNDLE_ID="com.joshsaintjacque.JBench"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

"$ROOT_DIR/script/package_app.sh" --configuration debug

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
