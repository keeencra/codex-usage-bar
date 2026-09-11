#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUTPUT_DIR:-$ROOT/build}"
APP="$OUT/CodexUsageBarTotal.app"
NEXT_APP="$(/usr/bin/mktemp -d /tmp/codex-usage-build.XXXXXX)/CodexUsageBarTotal.app"
NEXT_BIN="$NEXT_APP/Contents/MacOS/CodexUsageBar"
trap 'rm -rf "$(dirname "$NEXT_APP")"' EXIT

clean_xattrs() {
  local path="$1"
  xattr -cr "$path" 2>/dev/null || true
  xattr -dr com.apple.FinderInfo "$path" 2>/dev/null || true
  xattr -dr 'com.apple.fileprovider.fpfs#P' "$path" 2>/dev/null || true
  xattr -dr com.apple.ResourceFork "$path" 2>/dev/null || true
  xattr -dr com.apple.provenance "$path" 2>/dev/null || true
}

mkdir -p "$NEXT_APP/Contents/MacOS" "$NEXT_APP/Contents/Resources"

swiftc \
  -O \
  -framework AppKit \
  "$ROOT/main.swift" \
  -o "$NEXT_BIN"

cat > "$NEXT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>CodexUsageBar</string>
  <key>CFBundleIdentifier</key>
  <string>local.codex.usagebar</string>
  <key>CFBundleName</key>
  <string>CodexUsageBar</string>
  <key>CFBundleDisplayName</key>
  <string>Codex Usage Bar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.10.0</string>
  <key>CFBundleVersion</key>
  <string>17</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

chmod +x "$NEXT_BIN"
clean_xattrs "$NEXT_APP"
codesign --force --deep --sign - "$NEXT_APP" >/dev/null
ditto "$NEXT_APP" "$APP"
clean_xattrs "$APP"
codesign --force --deep --sign - "$APP" >/dev/null
echo "$APP"
