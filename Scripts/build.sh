#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex Usage Helper"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE_DIR="$ROOT_DIR/build/ModuleCache"

/bin/rm -rf "$ROOT_DIR/build"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$MODULE_CACHE_DIR"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

xcrun swiftc \
  -target arm64-apple-macosx13.0 \
  -module-cache-path "$MODULE_CACHE_DIR" \
  "$ROOT_DIR/Sources/CodexUsageHelper/main.swift" \
  -framework AppKit \
  -framework Carbon \
  -o "$MACOS_DIR/CodexUsageHelper"

"$MACOS_DIR/CodexUsageHelper" --make-icns "$RESOURCES_DIR/AppIcon.icns"
codesign --force --deep --sign - "$APP_DIR" >/dev/null
touch "$APP_DIR"

echo "$APP_DIR"
