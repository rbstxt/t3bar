#!/bin/zsh
# Packages ad-hoc signed universal T3Bar.app into release .zip, .dmg, and SHA256SUMS.txt.
# Usage: ./scripts/package-release.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
VERSION="${VERSION#v}"

VERSION="$VERSION" ./scripts/build-app.sh

BIN="build/T3Bar.app/Contents/MacOS/T3Bar"
ARCHS="$(lipo -archs "$BIN")"
if [[ "$ARCHS" != *"arm64"* || "$ARCHS" != *"x86_64"* ]]; then
  echo "Expected universal binary (arm64 + x86_64), got: $ARCHS" >&2
  exit 1
fi

OUT="build/release"
rm -rf "$OUT"
mkdir -p "$OUT"

ZIP_NAME="T3Bar-${VERSION}-macos-universal.zip"
DMG_NAME="T3Bar-${VERSION}-macos-universal.dmg"

ditto -c -k --sequesterRsrc --keepParent build/T3Bar.app "$OUT/$ZIP_NAME"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R build/T3Bar.app "$STAGE/T3Bar.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create \
  -volname "T3Bar ${VERSION}" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$OUT/$DMG_NAME" >/dev/null

(cd "$OUT" && shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS.txt)

echo "Packaged release artifacts in $OUT:"
cat "$OUT/SHA256SUMS.txt"
