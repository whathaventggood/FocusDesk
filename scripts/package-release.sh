#!/bin/bash
# Tested arm64 release candidate. No upload, keychain import, or system changes.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
PLIST="$PROJECT_ROOT/FocusDesk/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
EXPECTED_TAG="v$VERSION"
if [[ "${GITHUB_REF_TYPE:-}" == "tag" && "${GITHUB_REF_NAME:-}" != "$EXPECTED_TAG" ]]; then
  printf 'Release tag must match Info.plist: expected %s, got %s\n' "$EXPECTED_TAG" "$GITHUB_REF_NAME" >&2
  exit 1
fi

SIGNING_MODE="${FOCUSDESK_SIGNING_MODE:-adhoc}"
case "$SIGNING_MODE" in
  adhoc) ;;
  developer-id)
    for required_name in FOCUSDESK_SIGNING_IDENTITY APPLE_ID APPLE_TEAM_ID APPLE_APP_SPECIFIC_PASSWORD; do
      if [[ -z "${!required_name:-}" ]]; then
        printf 'Developer ID signing requires %s. Nothing will be uploaded.\n' "$required_name" >&2
        exit 1
      fi
    done
    if [[ "$FOCUSDESK_SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
      printf 'Use a Developer ID Application identity for distribution.\n' >&2
      exit 1
    fi
    ;;
  *) printf 'Unknown FOCUSDESK_SIGNING_MODE: %s\n' "$SIGNING_MODE" >&2; exit 2 ;;
esac

# The script cannot produce a release candidate from failing XCTest results.
"$PROJECT_ROOT/scripts/test-xcode.sh"

BUILD_ROOT="$PROJECT_ROOT/build"
OUTPUT_PATH="$BUILD_ROOT/release"
mkdir -p "$OUTPUT_PATH" "$BUILD_ROOT/tmp"
export TMPDIR="$BUILD_ROOT/tmp/"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/ModuleCache"

xcodebuild \
  -project FocusDesk.xcodeproj \
  -scheme FocusDesk \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_ROOT/ReleaseDerivedData" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/ModuleCache" \
  build

APP_PATH="$OUTPUT_PATH/FocusDesk.app"
if [[ -e "$APP_PATH" ]]; then
  rm -rf "$APP_PATH"
fi
ditto "$BUILD_ROOT/ReleaseDerivedData/Build/Products/Release/FocusDesk.app" "$APP_PATH"
# Strip build-provider metadata only from this newly generated bundle.
xattr -cr "$APP_PATH"

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  codesign --force --options runtime --timestamp --sign "$FOCUSDESK_SIGNING_IDENTITY" "$APP_PATH"
else
  codesign --force --sign - "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"
lipo "$APP_PATH/Contents/MacOS/FocusDesk" -verify_arch arm64

ZIP_NAME="FocusDesk-$VERSION-arm64.zip"
ZIP_PATH="$OUTPUT_PATH/$ZIP_NAME"
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$APP_PATH" "$ZIP_PATH"

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
  xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait --output-format json > "$OUTPUT_PATH/notarization.json"
  if ! /usr/bin/plutil -extract status raw -o - "$OUTPUT_PATH/notarization.json" | /usr/bin/grep -qx Accepted; then
    printf 'Apple notarization was not accepted. See build/release/notarization.json.\n' >&2
    exit 1
  fi
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  codesign --verify --deep --strict "$APP_PATH"
  if ! ASSESSMENT_OUTPUT="$(spctl --assess --type execute --verbose=2 "$APP_PATH" 2>&1)"; then
    printf 'Gatekeeper rejected the notarized app:\n%s\n' "$ASSESSMENT_OUTPUT" >&2
    exit 1
  fi
  printf '%s\n' "$ASSESSMENT_OUTPUT"
  if [[ "$ASSESSMENT_OUTPUT" != *"source=Notarized Developer ID"* ]]; then
    printf 'Gatekeeper did not identify this app as Notarized Developer ID.\n' >&2
    exit 1
  fi
  # Stapling changes the app; recreate the actual downloadable archive.
  ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$APP_PATH" "$ZIP_PATH"
  SIGNING_DESCRIPTION='Developer ID signed and Apple notarized; stapled ticket validated.'
else
  SIGNING_DESCRIPTION='Ad-hoc signed community build; not Developer ID signed or Apple notarized. Gatekeeper may block first launch. See INSTALL.md before installing.'
fi

(cd "$OUTPUT_PATH" && shasum -a 256 "$ZIP_NAME" > SHA256SUMS.txt)
cp "$PROJECT_ROOT/docs/INSTALL.md" "$OUTPUT_PATH/INSTALL.md"
{
  printf '# FocusDesk %s\n\n%s\n\n' "$VERSION" "$SIGNING_DESCRIPTION"
  awk -v heading="## [$VERSION]" '
    index($0, heading) == 1 { found = 1; next }
    found && /^## \[/ { exit }
    found { print }
  ' "$PROJECT_ROOT/CHANGELOG.md"
  printf '\nDownload `%s`, `SHA256SUMS.txt`, and `INSTALL.md` from this release.\n' "$ZIP_NAME"
  printf '\nBuilt from commit: `%s`.\n' "$(git rev-parse HEAD)"
} > "$OUTPUT_PATH/ReleaseNotes.md"
printf '\nRelease candidate: %s\n%s\n' "$ZIP_PATH" "$SIGNING_DESCRIPTION"
printf 'Nothing has been uploaded or published.\n'
