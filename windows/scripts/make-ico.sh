#!/bin/bash
# Builds Assets/Yowl.ico from the same drawing code as the Mac icon
# (Scripts/make-icon.swift), so the two apps cannot drift apart. Needs a Mac;
# the .ico is committed so Windows builds do not.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
swiftc -O ../Scripts/make-icon.swift -o "${WORK}/make-icon" 2>/dev/null
"${WORK}/make-icon" "${WORK}/AppIcon.iconset" >/dev/null
python3 - "${WORK}/AppIcon.iconset" src/Yowl.Windows/Assets/Yowl.ico <<'PY'
import struct, sys, os
# ICO entries may hold PNG data directly (Windows Vista and later).
sizes = {16: "icon_16x16.png", 32: "icon_32x32.png", 64: "icon_32x32@2x.png",
         128: "icon_128x128.png", 256: "icon_256x256.png"}
src, out = sys.argv[1], sys.argv[2]
images = [(s, open(os.path.join(src, f), "rb").read()) for s, f in sizes.items() if f]
header = struct.pack("<HHH", 0, 1, len(images))
offset = 6 + 16 * len(images)
entries, blobs = b"", b""
for size, data in images:
    dim = 0 if size >= 256 else size
    entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset)
    offset += len(data); blobs += data
open(out, "wb").write(header + entries + blobs)
print(f"wrote {out}: {[s for s, _ in images]}")
PY
