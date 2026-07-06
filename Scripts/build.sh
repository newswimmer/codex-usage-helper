#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex Usage Helper"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE_DIR="$ROOT_DIR/build/ModuleCache"

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$MODULE_CACHE_DIR"
/bin/rm -rf "$CONTENTS_DIR/_CodeSignature"
/bin/rm -f "$APP_DIR/Icon"$'\r'
xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
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
"$MACOS_DIR/CodexUsageHelper" --apply-finder-icon "$APP_DIR" "$RESOURCES_DIR/AppIcon.icns"
touch "$APP_DIR"

echo "$APP_DIR"
