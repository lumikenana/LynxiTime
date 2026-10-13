#!/bin/bash
# 由 Assets/AppIconSource.png（建议 1024×1024 以上方形 PNG）生成 Assets/AppIcon.icns
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="Assets/AppIconSource.png"
OUT="Assets/AppIcon.icns"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

# 先归一化到 1024×1024，保证 @2x 小图清晰
BASE="$(dirname "$SRC")/AppIcon_1024.png"
sips -z 1024 1024 "$SRC" --out "$BASE" >/dev/null

gen() { sips -z "$1" "$1" "$BASE" --out "$ICONSET/$2.png" >/dev/null; }
gen 16   icon_16x16
gen 32   icon_16x16@2x
gen 32   icon_32x32
gen 64   icon_32x32@2x
gen 128  icon_128x128
gen 256  icon_128x128@2x
gen 256  icon_256x256
gen 512  icon_256x256@2x
gen 512  icon_512x512
gen 1024 icon_512x512@2x

iconutil -c icns "$ICONSET" -o "$OUT"
echo "✅ $OUT"
