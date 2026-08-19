#!/usr/bin/env bash
set -euo pipefail

APP_NAME="JBench"
BUNDLE_ID="com.joshsaintjacque.JBench"
MIN_SYSTEM_VERSION="26.0"
CONFIGURATION="debug"
ADHOC_SIGN=false

usage() {
  echo "usage: $0 [--configuration debug|release] [--adhoc-sign]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      if [[ $# -lt 2 ]]; then
        usage
        exit 2
      fi
      CONFIGURATION="$2"
      shift 2
      ;;
    --adhoc-sign)
      ADHOC_SIGN=true
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$CONFIGURATION" in
  debug|release) ;;
  *)
    usage
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_BINARY="$APP_MACOS/$APP_NAME"
PROCESS_LAUNCHER="$APP_HELPERS/JBenchProcessLauncher"
INFO_PLIST="$APP_CONTENTS/Info.plist"

swift build --configuration "$CONFIGURATION"
BUILD_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"
BUILD_PROCESS_LAUNCHER="$BUILD_DIR/JBenchProcessLauncher"

if [[ "$APP_BUNDLE" != "$ROOT_DIR/dist/$APP_NAME.app" ]]; then
  echo "refusing unexpected app bundle path: $APP_BUNDLE" >&2
  exit 1
fi
if [[ -e "$APP_BUNDLE" ]]; then
  rm -r "$APP_BUNDLE"
fi

mkdir -p "$APP_MACOS" "$APP_HELPERS"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$BUILD_PROCESS_LAUNCHER" "$PROCESS_LAUNCHER"
chmod +x "$APP_BINARY" "$PROCESS_LAUNCHER"

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

if [[ "$ADHOC_SIGN" == true ]]; then
  /usr/bin/codesign --force --sign - "$PROCESS_LAUNCHER"
  /usr/bin/codesign --force --sign - "$APP_BUNDLE"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
fi

echo "$APP_BUNDLE"
