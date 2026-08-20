#!/usr/bin/env bash
# build.sh — compile SidePulseMac and assemble SidePulse.app.
#
# Produces a double-clickable, ad-hoc signed app bundle in ./dist. Ad-hoc
# signing is enough to run on the machine that built it and is what makes
# Bonjour/local-network prompts behave; see "Making it production ready" in
# ../../README.md for Developer ID signing and notarisation.
#
#   ./build.sh              release build -> dist/SidePulse.app
#   ./build.sh --install    also copy into /Applications
#   ./build.sh --run        also (re)launch it
#   ./build.sh --universal  include Apple silicon and Intel
set -euo pipefail

cd "$(dirname "$0")"

CONFIG=release
APP_NAME="SidePulse"
BUNDLE="dist/${APP_NAME}.app"
DO_INSTALL=0
DO_RUN=0
ARCH_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --install) DO_INSTALL=1 ;;
    --run) DO_RUN=1 ;;
    --debug) CONFIG=debug ;;
    --universal) ARCH_ARGS=(--arch arm64 --arch x86_64) ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "==> swift build -c $CONFIG"
if [ "${#ARCH_ARGS[@]}" -gt 0 ]; then
  swift build -c "$CONFIG" "${ARCH_ARGS[@]}"
  BIN="$(swift build -c "$CONFIG" "${ARCH_ARGS[@]}" --show-bin-path)/SidePulseMac"
else
  swift build -c "$CONFIG"
  BIN="$(swift build -c "$CONFIG" --show-bin-path)/SidePulseMac"
fi
[ -x "$BIN" ] || { echo "build produced no binary at $BIN" >&2; exit 1; }

echo "==> assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/SidePulseMac"
cp Info.plist "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"
mkdir -p "$BUNDLE/Contents/Resources/Helpers"
for helper in sidepulse sidepulse-solo sidepulse-event; do
  install -m 0755 "../../cli/$helper" "$BUNDLE/Contents/Resources/Helpers/$helper"
done

RESOURCE_BUNDLE="$(dirname "$BIN")/SidePulseMac_SidePulseMac.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "$BUNDLE/Contents/Resources/"
fi

# An app icon is optional; reuse the phone app's if it is present.
ICON_SRC="../../ios/SidePulseSim/SidePulseSim/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
if [ -f "$ICON_SRC" ] && command -v iconutil >/dev/null 2>&1; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1 || true
  rm -rf "$(dirname "$ICONSET")"
fi

# Ad-hoc signature. Without any signature macOS re-prompts for local network
# access on every launch, because the identity it keys the grant to keeps changing.
codesign --force --sign - --identifier com.sidepulse.mac "$BUNDLE"
codesign --verify --strict "$BUNDLE" && echo "==> signed (ad-hoc) and verified"

if [ "$DO_INSTALL" = 1 ]; then
  echo "==> installing to /Applications"
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$BUNDLE" "/Applications/${APP_NAME}.app"
fi

if [ "$DO_RUN" = 1 ]; then
  TARGET="$BUNDLE"
  [ "$DO_INSTALL" = 1 ] && TARGET="/Applications/${APP_NAME}.app"
  pkill -x SidePulseMac 2>/dev/null || true
  sleep 0.5
  open "$TARGET"
  echo "==> launched; look for the LED strip in the menu bar"
fi

echo "==> done: $BUNDLE"
