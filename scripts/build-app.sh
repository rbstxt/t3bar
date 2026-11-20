#!/bin/zsh
# Builds T3Bar.app into ./build. Pass --install to copy it to /Applications and launch it.
# Optional env vars: VERSION (CFBundleShortVersionString), BUILD_NUMBER (CFBundleVersion).
set -euo pipefail
cd "$(dirname "$0")/.."

TMPDIR_BUILD=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BUILD"' EXIT

APP=build/T3Bar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if swift build -c release --arch arm64 \
   && cp "$(swift build -c release --arch arm64 --show-bin-path)/T3Bar" "$TMPDIR_BUILD/T3Bar-arm64" \
   && swift build -c release --arch x86_64 \
   && cp "$(swift build -c release --arch x86_64 --show-bin-path)/T3Bar" "$TMPDIR_BUILD/T3Bar-x86_64"; then
  lipo -create "$TMPDIR_BUILD/T3Bar-arm64" "$TMPDIR_BUILD/T3Bar-x86_64" -output "$APP/Contents/MacOS/T3Bar"
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/T3Bar"
  cp "$BIN" "$APP/Contents/MacOS/T3Bar"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

# App icon from assets/icon.svg (needs rsvg-convert; skipped otherwise).
if command -v rsvg-convert >/dev/null; then
  ICONSET="$TMPDIR_BUILD/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    rsvg-convert -w $size -h $size assets/icon.svg -o "$ICONSET/icon_${size}x${size}.png"
    rsvg-convert -w $((size * 2)) -h $((size * 2)) assets/icon.svg -o "$ICONSET/icon_${size}x${size}@2x.png"
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x T3Bar 2>/dev/null || true
  rm -rf /Applications/T3Bar.app
  cp -R "$APP" /Applications/T3Bar.app
  open /Applications/T3Bar.app
  echo "Installed /Applications/T3Bar.app"
fi
