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

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock icon, no main window. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature is enough for local runs; Phase 6 switches to Developer ID.
# No --deep: it is deprecated and is not a valid way to sign for Developer ID /
# notarisation, which this command seeds. Nested code, when there is any, must
# be signed inside-out before the bundle itself.
codesign --force --sign - "${APP_DIR}"
echo "Built ${APP_DIR}"
