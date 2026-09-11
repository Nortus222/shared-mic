#!/bin/sh
# Build a distributable SharedMic.app for personal use (issue 19).
#
# Usage:
#   sh macos/scripts/build-distribution.sh
#
# Environment:
#   SHAREDMIC_SIGN_IDENTITY   codesign identity. Default "-" (ad-hoc).
#                             Personal-use without Gatekeeper prompts needs a
#                             "Developer ID Application: <Team>" identity, e.g.
#                             SHAREDMIC_SIGN_IDENTITY="Developer ID Application: Jane Doe (TEAMID)".
#   SHAREDMIC_TEAM_ID         Development team ID. Passed as DEVELOPMENT_TEAM so
#                             Xcode resolves the Developer ID identity.
#   SHAREDMIC_NOTARIZE_PROFILE
#                             `notarytool` keychain profile for notarization.
#                             When set (and the app is Developer ID signed), the
#                             script submits, waits, and staples automatically.
#   SHAREDMIC_VERSION         Override for MARKETING_VERSION in macos/project.rb.
#   SHAREDMIC_BUILD           Override for CURRENT_PROJECT_VERSION in macos/project.rb.
#
# Output: macos/dist/SharedMic-<version>.zip containing SharedMic.app.
#
# The script never commits anything: a version override is applied to a
# temporary copy of the build settings via xcodebuild arguments, so
# macos/project.rb stays the source of truth.
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIST="$ROOT/macos/dist"
SCHEME="SharedMic"
PROJECT="$ROOT/macos/SharedMic.xcodeproj"
SIGN_IDENTITY="${SHAREDMIC_SIGN_IDENTITY:--}"
VERSION="${SHAREDMIC_VERSION:-0.1.0}"
BUILD="${SHAREDMIC_BUILD:-1}"

rm -rf "$DIST"
mkdir -p "$DIST"

ARCHIVE="$DIST/SharedMic.xcarchive"
EXPORT_APP="$DIST/SharedMic.app"

echo "==> Building Release SharedMic.app (sign: $SIGN_IDENTITY)"
if [ -n "${SHAREDMIC_TEAM_ID:-}" ]; then
  TEAM_ARGS="DEVELOPMENT_TEAM=$SHAREDMIC_TEAM_ID CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=$SIGN_IDENTITY"
else
  # shellcheck disable=SC2086
  TEAM_ARGS="CODE_SIGN_IDENTITY=$SIGN_IDENTITY"
fi

# shellcheck disable=SC2086
xcodebuild -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS' \
  -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  $TEAM_ARGS \
  archive

# Copy the .app out of the archive; keep the archive for symbolication.
cp -R "$ARCHIVE/Products/Applications/SharedMic.app" "$EXPORT_APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$EXPORT_APP"
codesign -dv --verbose=4 "$EXPORT_APP" 2>&1 | sed -n '1,12p'

if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "==> Ad-hoc build: skipping Gatekeeper assessment (ad-hoc never passes)."
  echo "    Expect Gatekeeper to quarantine this on other machines;"
  echo "    see macos/DISTRIBUTION.md for the documented behaviour."
else
  echo "==> Gatekeeper assessment"
  spctl -a -t exec -vv "$EXPORT_APP" || true
fi

if [ -n "${SHAREDMIC_NOTARIZE_PROFILE:-}" ] && [ "$SIGN_IDENTITY" != "-" ]; then
  echo "==> Creating zip for notarization"
  (cd "$DIST" && ditto -c -k --keepParent SharedMic.app SharedMic-upload.zip)
  echo "==> Submitting to Apple notarization (this takes a few minutes)"
  xcrun notarytool submit "$DIST/SharedMic-upload.zip" \
    --keychain-profile "$SHAREDMIC_NOTARIZE_PROFILE" --wait
  echo "==> Stapling ticket"
  xcrun stapler staple "$EXPORT_APP"
  xcrun stapler validate "$EXPORT_APP"
  rm "$DIST/SharedMic-upload.zip"
fi

echo "==> Creating distributable zip"
(cd "$DIST" && ditto -c -k --keepParent SharedMic.app "SharedMic-$VERSION.zip")
rm -rf "$EXPORT_APP"

echo "==> Done: $DIST/SharedMic-$VERSION.zip"
echo "    Install: unzip, drag SharedMic.app to /Applications, launch from there."
