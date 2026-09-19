#!/bin/bash
# Builds, signs, notarises and packages Yowl for direct download.
#
# Needs two things that only a human with the Apple account can create:
#   1. A "Developer ID Application" certificate
#        Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
#      (This is NOT the same as "Apple Development", which cannot be notarised.)
#   2. Notarisation credentials stored in the keychain:
#        xcrun notarytool store-credentials yowl \
#          --apple-id you@example.com --team-id <INDIGO-LABS-TEAM-ID> \
#          --password <app-specific-password-from-appleid.apple.com>
set -euo pipefail

APP_NAME="Yowl"
VERSION="${1:-1.0.0}"
APP_DIR="build/${APP_NAME}.app"
DMG="build/${APP_NAME}-${VERSION}.dmg"
PROFILE="yowl"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "Checking prerequisites"
IDENTITY="${YOWL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')}"
if [ -z "${IDENTITY}" ]; then
    cat >&2 <<'MSG'
error: no "Developer ID Application" certificate found.

  Apple Development certificates cannot be notarised, so macOS will show
  "cannot be opened because the developer cannot be verified" to everyone
  who downloads this.

  Create one: Xcode > Settings > Accounts > Manage Certificates > + >
  Developer ID Application. Requires the paid Apple Developer Program and
  an Account Holder or Admin role.
MSG
    exit 1
fi
echo "signing identity: ${IDENTITY}"

if ! xcrun notarytool history --keychain-profile "${PROFILE}" >/dev/null 2>&1; then
    cat >&2 <<MSG
error: no notarisation credentials stored under profile "${PROFILE}".

  xcrun notarytool store-credentials ${PROFILE} \\
    --apple-id <your-apple-id> --team-id <INDIGO-LABS-TEAM-ID> \\
    --password <app-specific-password>

  App-specific passwords come from appleid.apple.com > Sign-In and Security.
MSG
    exit 1
fi

step "Running tests"
swift test 2>&1 | tail -3

step "Building and signing ${VERSION}"
YOWL_SIGN_IDENTITY="${IDENTITY}" YOWL_VERSION="${VERSION}" ./Scripts/make-bundle.sh
codesign --verify --strict --deep-verify "${APP_DIR}"
echo "signature verified"

# Two notarisation passes, and both are load-bearing.
#
# The app is notarised and stapled FIRST, so its ticket travels inside the
# bundle. Stapling only the disk image leaves the app unable to prove itself
# once it has been dragged out of it, and a first launch with no network then
# warns -- verified: the app inside a DMG-only-stapled image reported "does not
# have a ticket stapled to it".
#
# The image is then signed and notarised in its own right. An unsigned DMG is
# assessed as "no usable signature", and nothing detects tampering with it
# between Apple and the person downloading it.
step "Notarising the app (this usually takes a few minutes)"
APP_ZIP="$(mktemp -d)/${APP_NAME}.zip"
ditto -c -k --keepParent "${APP_DIR}" "${APP_ZIP}"
xcrun notarytool submit "${APP_ZIP}" --keychain-profile "${PROFILE}" --wait
rm -rf "$(dirname "${APP_ZIP}")"

step "Stapling the app"
xcrun stapler staple "${APP_DIR}"
xcrun stapler validate "${APP_DIR}"

step "Packaging disk image"
# Built read-write first so Finder can be told where the icons go and what sits
# behind them, then flattened to a compressed read-only image. A plain UDZO
# gives you two unplaced icons on a white void, which is a poor first thing to
# show someone who just downloaded a security app.
rm -f "${DMG}"
STAGING="$(mktemp -d)/${APP_NAME}"
mkdir -p "${STAGING}/.background"
cp -R "${APP_DIR}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

BGBIN="$(mktemp -d)/make-bg"
swiftc -O Scripts/make-dmg-background.swift -o "${BGBIN}" 2>/dev/null
"${BGBIN}" "${STAGING}/.background" >/dev/null
rm -rf "$(dirname "${BGBIN}")"

RW="$(mktemp -d)/rw.dmg"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING}" -ov \
    -format UDRW -fs HFS+ "${RW}" >/dev/null
rm -rf "$(dirname "${STAGING}")"

MOUNT="$(hdiutil attach "${RW}" -nobrowse -noautoopen | tail -1 | \
    sed 's/.*\(\/Volumes\/.*\)/\1/')"
# The volume name is read back rather than assumed. A stale /Volumes/Yowl from
# an earlier mount makes macOS name this one "Yowl 1", and an AppleScript that
# says `tell disk "Yowl"` then quietly decorates the wrong, read-only volume and
# reports success -- which is exactly how this shipped an unstyled image once.
VOLNAME="$(basename "${MOUNT}")"

# Positions match ICON_TOP and the icon columns in make-dmg-background.swift.
# Finder automation can be refused (it needs permission the first time), and a
# plain image still installs fine, so this warns rather than failing the build.
if ! osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Finder"
    tell disk "${VOLNAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 820, 560}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 118
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:bg.png"
        set position of item "${APP_NAME}.app" of container window to {165, 248}
        set position of item "Applications" of container window to {455, 248}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT
then
    echo "warning: Finder would not arrange the disk image window." >&2
    echo "         The image still installs; it just looks plain. Grant" >&2
    echo "         Finder automation in System Settings and re-run." >&2
fi

sync
# Finder writes the window layout to .DS_Store. No .DS_Store means the layout
# did not take, whatever osascript's exit status claimed.
if [ ! -f "${MOUNT}/.DS_Store" ]; then
    echo "warning: the disk image window was not styled (no .DS_Store written)." >&2
    echo "         It installs correctly but opens plain." >&2
fi
hdiutil detach "${MOUNT}" -quiet
hdiutil convert "${RW}" -format UDZO -imagekey zlib-level=9 -ov -o "${DMG}" >/dev/null
rm -rf "$(dirname "${RW}")"
codesign --force --sign "${IDENTITY}" "${DMG}"
echo "created and signed ${DMG}"

step "Notarising the disk image"
xcrun notarytool submit "${DMG}" --keychain-profile "${PROFILE}" --wait

step "Stapling the disk image"
xcrun stapler staple "${DMG}"
xcrun stapler validate "${DMG}"

step "Done"
spctl --assess --type open --context context:primary-signature -v "${DMG}"
echo
echo "Ship this file: ${DMG}"
echo "It will open on any Mac without a Gatekeeper warning."
