#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP=NetbirdRouting.app
ARCH="$(uname -m)"
case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Explicit allowlist: test code must never be shipped.
swiftc -O -target "$ARCH-apple-macosx13.0" Sources/main.swift Sources/Models.swift Sources/PresetStore.swift \
    Sources/NetbirdClient.swift Sources/RoutingController.swift \
    Sources/ManagerController.swift Sources/MenuViews.swift Sources/TrayController.swift \
    -o "$APP/Contents/MacOS/NetbirdRouting"
MIN_OS="$(xcrun vtool -show-build "$APP/Contents/MacOS/NetbirdRouting" | awk '/minos/ {print $2}')"
if [[ "$MIN_OS" != "13.0" ]]; then
    echo "Unexpected binary deployment target: $MIN_OS (expected 13.0)" >&2
    exit 1
fi

# App icon: "R" iconset -> AppIcon.icns
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift tools/make_icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>NetbirdRouting</string>
    <key>CFBundleDisplayName</key>     <string>NetBird Routing</string>
    <key>CFBundleIdentifier</key>      <string>dev.andrey.netbirdrouting</string>
    <key>CFBundleExecutable</key>      <string>NetbirdRouting</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
EOF

codesign --force -s - "$APP"
# A raw executable needs Finder metadata for its icon. Keep that metadata OUT of
# the signed app bundle; provide a separate standalone copy for Finder/CLI use.
STANDALONE=build/NetbirdRouting
cp "$APP/Contents/MacOS/NetbirdRouting" "$STANDALONE"
# The copied bundle signature references the app's Info.plist. Re-sign the raw
# Mach-O independently so its signature can be verified outside the bundle.
codesign --force -s - --identifier dev.andrey.netbirdrouting.cli "$STANDALONE"
swift tools/set_executable_icon.swift "$STANDALONE" "$APP/Contents/Resources/AppIcon.icns"
codesign --verify --strict "$APP"
# Strict verification intentionally rejects Finder custom-icon metadata on raw
# files; use normal verification here. The app itself stays strict-clean.
codesign --verify "$STANDALONE"
echo "Built: $(pwd)/$APP"
echo "Standalone executable with Finder icon: $(pwd)/$STANDALONE"
