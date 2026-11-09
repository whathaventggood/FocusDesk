#!/bin/bash
# Build an Apple Silicon macOS app without requiring the full Xcode installation.
set -euo pipefail

# The system pwd resolves on-disk casing; Bash's builtin can retain "desktop".
# Clang module caches must always see the same absolute project path.
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
cd "$PROJECT_ROOT"
BUILD_ROOT="$PROJECT_ROOT/build"
CONFIGURATION="${1:-Release}"

case "$CONFIGURATION" in
  Debug) OPTIMIZATION="-Onone" ;;
  Release) OPTIMIZATION="-O" ;;
  *) printf 'Usage: %s [Debug|Release]\n' "$0" >&2; exit 2 ;;
esac

APP_PATH="$BUILD_ROOT/$CONFIGURATION/FocusDesk.app"
MODULE_CACHE="$BUILD_ROOT/ModuleCache"
BUILD_TMP="$BUILD_ROOT/tmp"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$MODULE_CACHE" "$BUILD_TMP"

# Keep compiler temporary files and module caches inside the project.
export TMPDIR="$BUILD_TMP/"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SWIFT_COMPILER="$(xcrun --find swiftc)"
SOURCES=()
while IFS= read -r -d '' source_file; do
  SOURCES+=("$source_file")
done < <(find "$PROJECT_ROOT/FocusDesk" -type f -name '*.swift' -print0)

if [ "${#SOURCES[@]}" -eq 0 ]; then
  printf 'No Swift sources found in %s/FocusDesk.\n' "$PROJECT_ROOT" >&2
  exit 1
fi

"$SWIFT_COMPILER" \
  -swift-version 5 \
  -parse-as-library \
  -module-name FocusDesk \
  -target arm64-apple-macosx13.0 \
  -sdk "$SDK_PATH" \
  -module-cache-path "$MODULE_CACHE" \
  "$OPTIMIZATION" \
  -framework AppKit \
  -framework SwiftUI \
  -framework ServiceManagement \
  "${SOURCES[@]}" \
  -o "$APP_PATH/Contents/MacOS/FocusDesk"

cp "$PROJECT_ROOT/FocusDesk/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable FocusDesk' "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.focusdesk.FocusDesk' "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName FocusDesk' "$APP_PATH/Contents/Info.plist"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"

/usr/libexec/PlistBuddy -c "Add :FocusDeskDefaultLanguage string ${FOCUSDESK_DEFAULT_LANGUAGE:-zh-Hans}" "$APP_PATH/Contents/Info.plist"

# Seal a clean staging copy outside Desktop/iCloud. File providers can reattach
# FinderInfo immediately after xattr, even between clearing and signing a bundle.
SIGNING_ROOT="$(mktemp -d /private/tmp/FocusDesk-signing.XXXXXX)"
trap 'rm -rf "$SIGNING_ROOT"' EXIT
STAGED_APP="$SIGNING_ROOT/FocusDesk.app"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$APP_PATH" "$STAGED_APP"
/usr/bin/xattr -cr "$STAGED_APP"
/usr/bin/codesign --force --sign - "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$STAGED_APP" "$APP_PATH"

# Keep a portable copy without Finder/iCloud metadata. Some Desktop file
# providers reattach FinderInfo to .app folders after signing has finished.
ARCHIVE_PATH="$BUILD_ROOT/$CONFIGURATION/FocusDesk.zip"
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
  "$STAGED_APP" "$ARCHIVE_PATH"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGED_APP/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$STAGED_APP/Contents/Info.plist")"
VERSIONED_NAME="FocusDesk-$APP_VERSION-build$APP_BUILD.zip"
cp "$ARCHIVE_PATH" "$BUILD_ROOT/$CONFIGURATION/$VERSIONED_NAME"
(cd "$BUILD_ROOT/$CONFIGURATION" && shasum -a 256 FocusDesk.zip "$VERSIONED_NAME" > SHA256SUMS.txt)

printf '\nBuilt %s\n' "$APP_PATH"
printf 'Portable archive: %s\n' "$ARCHIVE_PATH"
printf 'Versioned archive: %s\n' "$BUILD_ROOT/$CONFIGURATION/$VERSIONED_NAME"
printf 'Ad-hoc signed local build; not Developer ID signed or Apple notarized.\n'
printf 'Open the app yourself when ready; this script does not launch it.\n'
