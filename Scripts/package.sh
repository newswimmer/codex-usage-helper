#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex Usage Helper"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
DIST_DIR="$ROOT_DIR/dist"
ZIP_PATH="$DIST_DIR/CodexUsageHelper-v$VERSION.zip"

"$ROOT_DIR/Scripts/build.sh" >/dev/null
/bin/rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

(
  cd "$ROOT_DIR/build"
  COPYFILE_DISABLE=1 /usr/bin/zip -qry -X "$ZIP_PATH" "$APP_NAME.app"
)

echo "$ZIP_PATH"
