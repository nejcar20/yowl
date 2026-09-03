#!/bin/bash
set -euo pipefail

APP_NAME="LaptopAlarm"
BUNDLE_ID="com.jernejkocica.laptopalarm"
BUILD_DIR=".build/release"
APP_DIR="build/${APP_NAME}.app"

swift build -c release --product "${APP_NAME}"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# The icon is generated from Scripts/make-icon.swift so it lives in the repo as
# code rather than as a binary nobody can edit.
ICONSET="$(mktemp -d)/AppIcon.iconset"
swiftc -O Scripts/make-icon.swift -o "$(dirname "${ICONSET}")/make-icon" 2>/dev/null
"$(dirname "${ICONSET}")/make-icon" "${ICONSET}" >/dev/null
iconutil -c icns "${ICONSET}" -o "${APP_DIR}/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "${ICONSET}")"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${LAPTOPALARM_VERSION:-0.1.0}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock icon, no main window. -->
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Jernej Jan Kocica. All rights reserved.</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <!-- Without this key macOS terminates the process the moment it touches the
         camera, rather than prompting. The wording is shown verbatim in the
         permission dialog and is the whole of the user's decision. -->
    <key>NSCameraUsageDescription</key>
    <string>LaptopAlarm watches for the laptop being picked up, and — if you switch it on — photographs whoever is in front of it when the alarm fires. Everything stays on this Mac unless you set up somewhere to send it.</string>
</dict>
</plist>
PLIST

# TCC ties the camera permission grant to the signing identity. An ad-hoc
# signature differs on every build, so the grant would be lost each time and the
# user re-prompted forever; a stable identity keeps it. Phase 6 switches to
# Developer ID for distribution.
# No --deep: it is deprecated and is not a valid way to sign for Developer ID /
# notarisation, which this command seeds. Nested code, when there is any, must
# be signed inside-out before the bundle itself.
# The hardened runtime blocks camera access outright unless the app carries this
# entitlement -- the permission prompt never even appears without it.
ENTITLEMENTS="$(mktemp -t laptopalarm-entitlements.plist)"
cat > "${ENTITLEMENTS}" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.camera</key><true/>
    <key>com.apple.security.network.client</key><true/>
</dict>
</plist>
ENT
trap 'rm -f "${ENTITLEMENTS}"' EXIT

IDENTITY="${LAPTOPALARM_SIGN_IDENTITY:-Apple Development: Jernej Jan Kocica (U2C2MA4YJZ)}"
# Captured to a variable first: `grep -q` exits on its first match and can
# SIGPIPE the producer, which under `set -o pipefail` fails the pipeline and
# silently takes the ad-hoc branch even when the identity exists.
IDENTITIES="$(security find-identity -v -p codesigning || true)"
if printf '%s' "${IDENTITIES}" | grep -qF "${IDENTITY}"; then
    codesign --force --options runtime --entitlements "${ENTITLEMENTS}" \
             --sign "${IDENTITY}" "${APP_DIR}"
else
    echo "warning: signing identity '${IDENTITY}' not found; falling back to ad-hoc." >&2
    echo "         The camera permission will be re-requested on every build." >&2
    codesign --force --sign - "${APP_DIR}"
fi
echo "Built ${APP_DIR}"
