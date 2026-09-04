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

step "Packaging disk image"
rm -f "${DMG}"
STAGING="$(mktemp -d)"
cp -R "${APP_DIR}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
cp docs/PRIVACY.md "${STAGING}/Privacy.md"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING}" -ov -format UDZO "${DMG}" >/dev/null
rm -rf "${STAGING}"
echo "created ${DMG}"

step "Notarising (this usually takes a few minutes)"
xcrun notarytool submit "${DMG}" --keychain-profile "${PROFILE}" --wait

step "Stapling"
xcrun stapler staple "${DMG}"
xcrun stapler validate "${DMG}"

step "Done"
spctl --assess --type open --context context:primary-signature -v "${DMG}" 2>&1 || true
echo
echo "Ship this file: ${DMG}"
echo "It will open on any Mac without a Gatekeeper warning."
