#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="$(uname -m)"
case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

APP=NetbirdRouting.app
STANDALONE=build/NetbirdRouting
test -x "$APP/Contents/MacOS/NetbirdRouting"
test -x "$STANDALONE"
codesign --verify --strict "$APP"
codesign --verify "$STANDALONE"
lipo -verify_arch "$ARCH" "$APP/Contents/MacOS/NetbirdRouting"
lipo -verify_arch "$ARCH" "$STANDALONE"
plutil -lint "$APP/Contents/Info.plist"

mkdir -p dist
APP_ZIP="NetbirdRouting-macos-$ARCH-app.zip"
CLI_ZIP="NetbirdRouting-macos-$ARCH-binary.zip"
# ditto preserves executable permissions, bundle structure and Finder metadata.
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$APP_ZIP"
(
    cd build
    ditto -c -k --sequesterRsrc NetbirdRouting "../dist/$CLI_ZIP"
)
(
    cd dist
    shasum -a 256 "$APP_ZIP" "$CLI_ZIP" > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)
