#!/usr/bin/env bash
# Build a self-contained GititApp.app bundle.
#
# A bare `swift run` executable launched from a terminal never owns the macOS
# menu bar, so ⌘-shortcuts and the Settings menu item (⌘,) do nothing. Launching
# a proper .app bundle fixes that, and gives the app a stable bundle identifier
# so UserDefaults (filter patterns, pane state) persists reliably across runs.
#
# Output: .build/GititApp.app  (.build/ is gitignored)
# Override the build configuration with CONFIG=debug (default: release).

set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PACKAGE_ROOT"

CONFIG="${CONFIG:-release}"

echo "==> building Rust core ($CONFIG)"
PROFILE="$CONFIG" "$PACKAGE_ROOT/build/build-rust.sh"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
EXECUTABLE="$BIN_DIR/GititApp"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "ERROR: built executable not found at $EXECUTABLE" >&2
    exit 1
fi

APP="$PACKAGE_ROOT/.build/GititApp.app"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$EXECUTABLE" "$APP/Contents/MacOS/GititApp"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>gitit</string>
    <key>CFBundleDisplayName</key>        <string>gitit</string>
    <key>CFBundleExecutable</key>         <string>GititApp</string>
    <key>CFBundleIdentifier</key>         <string>com.gitit.GititApp</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSMinimumSystemVersion</key>     <string>14.0</string>
    <key>NSPrincipalClass</key>           <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
PLIST

echo "==> done: $APP"
echo
echo "Launch it with:"
echo "    open \"$APP\""
