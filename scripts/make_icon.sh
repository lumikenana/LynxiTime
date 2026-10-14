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
W=$(sips -g pixelWidth "$SRC" | awk '/pixelWidth/{print $2}')
H=$(sips -g pixelHeight "$SRC" | awk '/pixelHeight/{print $2}')
NORMALIZED="$SRC"
if [ "$W" != "$H" ]; then
  # 非方形源图：居中补透明边到正方形，避免拉伸（sips 的 --pad 会填白，故用 python）
  PADDED="$(mktemp -d)/padded.png"
  python3 - "$SRC" "$PADDED" <<'PY'
import sys, struct, zlib

src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
pos = 8
idat = b""
while pos < len(data):
    ln = struct.unpack(">I", data[pos:pos+4])[0]
    typ = data[pos+4:pos+8]
    chunk = data[pos+8:pos+8+ln]
    if typ == b"IHDR":
        w, h, bd, ct = struct.unpack(">IIBB", chunk[:10])
        assert bd == 8 and ct == 6, "需要 8-bit RGBA PNG"
    elif typ == b"IDAT":
        idat += chunk
    pos += 12 + ln

raw = zlib.decompress(idat)
stride = w * 4
rows = []
i = 0
prev = bytearray(stride)
for _ in range(h):
    f = raw[i]; i += 1
    line = bytearray(raw[i:i+stride]); i += stride
    for x in range(stride):
        a = line[x-4] if x >= 4 else 0
        b = prev[x]
        c = prev[x-4] if x >= 4 else 0
        if f == 1: v = (line[x] + a) & 255
        elif f == 2: v = (line[x] + b) & 255
        elif f == 3: v = (line[x] + ((a + b) // 2)) & 255
        elif f == 4:
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            v = (line[x] + pr) & 255
        else: v = line[x]
        line[x] = v
    rows.append(bytes(line))
    prev = line

side = max(w, h)
ox, oy = (side - w) // 2, (side - h) // 2
empty = bytes(stride)
out_rows = [empty] * side
for y, row in enumerate(rows):
    out_rows[oy + y] = b"\x00\x00\x00\x00" * ox + row + b"\x00\x00\x00\x00" * (side - w - ox)

def chunk(typ, payload):
    return (struct.pack(">I", len(payload)) + typ + payload
            + struct.pack(">I", zlib.crc32(typ + payload) & 0xffffffff))

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(b"".join(b"\x00" + r for r in out_rows), 9))
       + chunk(b"IEND", b""))
open(dst, "wb").write(png)
PY
  NORMALIZED="$PADDED"
fi
sips -z 1024 1024 "$NORMALIZED" --out "$BASE" >/dev/null

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
