#!/bin/bash
# Builds the Microsoft Store tile and logo PNGs in packaging/Images from the
# same drawing code as the Mac icon (Scripts/make-icon.swift). Needs a Mac and
# ImageMagick; the PNGs are committed so Windows builds do not.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
swiftc -O ../Scripts/make-icon.swift -o "${WORK}/make-icon" 2>/dev/null
"${WORK}/make-icon" "${WORK}/AppIcon.iconset" >/dev/null
SRC="${WORK}/AppIcon.iconset/icon_512x512@2x.png"
OUT=packaging/Images
rm -rf "${OUT}"; mkdir -p "${OUT}"

# Icon of <size> centred on a transparent <w>x<h> canvas.
tile() { magick "${SRC}" -resize "$2x$2" -background none -gravity center -extent "$3x$4" -depth 8 "${OUT}/$1"; }

for scale in 100 200; do
  f=$((scale / 100))
  tile "Square44x44Logo.scale-${scale}.png" $((44 * f)) $((44 * f)) $((44 * f))
  tile "Square150x150Logo.scale-${scale}.png" $((110 * f)) $((150 * f)) $((150 * f))
  tile "Wide310x150Logo.scale-${scale}.png" $((110 * f)) $((310 * f)) $((150 * f))
  tile "StoreLogo.scale-${scale}.png" $((50 * f)) $((50 * f)) $((50 * f))
done
# Taskbar, Start and Explorer sizes. The icon has its own plate, so the
# unplated variants are the same image.
for size in 16 24 32 48 256; do
  tile "Square44x44Logo.targetsize-${size}.png" ${size} ${size} ${size}
  tile "Square44x44Logo.targetsize-${size}_altform-unplated.png" ${size} ${size} ${size}
done
ls "${OUT}"
