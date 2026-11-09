#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && /bin/pwd -P)"
cd "$project_root"
mkdir -p build/ux-validation/ModuleCache build/ux-validation/tmp
export TMPDIR="$project_root/build/ux-validation/tmp/"
xcrun swiftc -O -swift-version 5 -module-cache-path build/ux-validation/ModuleCache \
  FocusDesk/Models/AppLanguage.swift FocusDesk/Models/ActivityTimer.swift \
  FocusDesk/Services/ActivityTimerStore.swift scripts/check-performance.swift \
  -o build/ux-validation/FocusDeskPerformanceChecks
exec build/ux-validation/FocusDeskPerformanceChecks "$@"
