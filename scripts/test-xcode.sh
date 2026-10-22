#!/bin/bash
# Run the real app-hosted XCTest target. Never fall back to smoke checks.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
BUILD_ROOT="$PROJECT_ROOT/build"
mkdir -p "$BUILD_ROOT/tmp" "$BUILD_ROOT/ModuleCache" "$BUILD_ROOT/TestResults"
export TMPDIR="$BUILD_ROOT/tmp/"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/ModuleCache"
export SWIFT_MODULECACHE_PATH="$BUILD_ROOT/ModuleCache"

if ! xcodebuild -version; then
  printf '\nFull Xcode is required for XCTest. Command Line Tools alone cannot run this script.\n' >&2
  printf 'Install Xcode, open it once, then run with DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer if needed.\n' >&2
  exit 1
fi

ARCHITECTURE="${FOCUSDESK_TEST_ARCH:-$(uname -m)}"
RESULT_PATH="$BUILD_ROOT/TestResults/FocusDesk-$(date -u +%Y%m%dT%H%M%SZ)-$$.xcresult"
LOG_PATH="${RESULT_PATH%.xcresult}.log"

xcodebuild \
  -project FocusDesk.xcodeproj \
  -scheme FocusDesk \
  -configuration Debug \
  -destination "platform=macOS,arch=$ARCHITECTURE" \
  -derivedDataPath "$BUILD_ROOT/DerivedData" \
  -resultBundlePath "$RESULT_PATH" \
  -parallel-testing-enabled NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/ModuleCache" \
  build test 2>&1 | tee "$LOG_PATH"

printf '\nXCTest report: %s\n' "$RESULT_PATH"
