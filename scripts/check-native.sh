#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && /bin/pwd -P)"
cd "$project_root"
mkdir -p build/native-smoke/ModuleCache build/native-smoke/tmp build/native-smoke/FocusDeskSmoke.app/Contents/MacOS
export TMPDIR="$project_root/build/native-smoke/tmp"
export CLANG_MODULE_CACHE_PATH="$project_root/build/native-smoke/ModuleCache"
export SWIFT_MODULECACHE_PATH="$project_root/build/native-smoke/ModuleCache"

cat > build/native-smoke/FocusDeskSmoke.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FocusDeskSmoke</string>
<key>CFBundleIdentifier</key><string>com.focusdesk.native-smoke</string>
<key>CFBundleName</key><string>FocusDeskSmoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

xcrun swiftc \
  -swift-version 5 \
  -target arm64-apple-macosx13.0 \
  -module-cache-path build/native-smoke/ModuleCache \
  FocusDesk/Models/*.swift \
  FocusDesk/Services/*.swift \
  FocusDesk/Views/*.swift \
  FocusDesk/App/AppController.swift \
  scripts/check-native.swift \
  -o build/native-smoke/FocusDeskSmoke.app/Contents/MacOS/FocusDeskSmoke

if [[ "${1:-}" == "--build-only" ]]; then
  exit 0
fi

exec build/native-smoke/FocusDeskSmoke.app/Contents/MacOS/FocusDeskSmoke
