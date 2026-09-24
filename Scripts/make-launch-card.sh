#!/bin/bash
# Renders the launch card — the image that goes with the LinkedIn and Reddit
# posts — to docs/img/card.png.
#
# Generated rather than hand-made, for the same reason as the app icon and the
# disk image background: the artwork lives in the repo as source. Edit
# docs/launch/card.html and re-run this.
#
# It renders through headless Chrome because the card uses the same Google
# Fonts as the site (Oswald, Courier Prime). Anything that cannot load those
# silently falls back to a system sans, and the card stops looking like the
# rest of Yowl.
set -euo pipefail

OUT="docs/img/card.png"
PORT="${PORT:-8731}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

if [ ! -x "${CHROME}" ]; then
    echo "error: Google Chrome not found at ${CHROME}" >&2
    echo "       Set CHROME=/path/to/chrome and re-run." >&2
    exit 1
fi

# Served over HTTP rather than opened as a file:// URL: the card loads a
# screenshot from a sibling directory, which file:// origins refuse.
python3 -m http.server "${PORT}" --bind 127.0.0.1 >/dev/null 2>&1 &
SERVER=$!
trap 'kill "${SERVER}" 2>/dev/null || true' EXIT
until curl -sf -o /dev/null "http://127.0.0.1:${PORT}/docs/launch/card.html"; do sleep 0.2; done

# --virtual-time-budget is load-bearing. Without it Chrome screenshots before
# the webfonts arrive and the headline renders in the fallback sans.
"${CHROME}" --headless --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=2 --window-size=1200,1200 \
    --virtual-time-budget=8000 \
    --screenshot="${OUT}" \
    "http://127.0.0.1:${PORT}/docs/launch/card.html" 2>/dev/null

SIZE="$(sips -g pixelWidth -g pixelHeight "${OUT}" | awk '/pixel/{printf "%s ", $2}')"
echo "wrote ${OUT} (${SIZE%% })"
