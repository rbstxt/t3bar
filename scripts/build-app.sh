#!/bin/zsh
# Builds T3Bar.app into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64 2>/dev/null || swift build -c release
BIN="$(swift build -c release --show-bin-path 2>/dev/null)/T3Bar"
[[ -x "$BIN" ]] || BIN=".build/apple/Products/Release/T3Bar"

APP=build/T3Bar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/T3Bar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon from assets/icon.svg (needs rsvg-convert; skipped otherwise).
if command -v rsvg-convert >/dev/null; then
  ICONSET=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    rsvg-convert -w $size -h $size assets/icon.svg -o "$ICONSET/icon_${size}x${size}.png"
    rsvg-convert -w $((size * 2)) -h $((size * 2)) assets/icon.svg -o "$ICONSET/icon_${size}x${size}@2x.png"
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x T3Bar 2>/dev/null || true
  rm -rf /Applications/T3Bar.app
  cp -R "$APP" /Applications/T3Bar.app
  open /Applications/T3Bar.app
  echo "Installed /Applications/T3Bar.app"
fi
