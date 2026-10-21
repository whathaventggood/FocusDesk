#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_BUILD_DIR="$PROJECT_ROOT/build/core-checks"
mkdir -p "$CHECK_BUILD_DIR/ModuleCache" "$CHECK_BUILD_DIR/tmp"

export CLANG_MODULE_CACHE_PATH="$CHECK_BUILD_DIR/ModuleCache"
export SWIFT_MODULECACHE_PATH="$CHECK_BUILD_DIR/ModuleCache"
export TMPDIR="$CHECK_BUILD_DIR/tmp"

xcrun swiftc -swift-version 5 \
    -module-cache-path "$CHECK_BUILD_DIR/ModuleCache" \
    "$PROJECT_ROOT/FocusDesk/Models/PlanTask.swift" \
    "$PROJECT_ROOT/FocusDesk/Models/DefaultPlan.swift" \
    "$PROJECT_ROOT/FocusDesk/Services/ScheduleEngine.swift" \
    "$PROJECT_ROOT/scripts/check-core.swift" \
    -o "$CHECK_BUILD_DIR/FocusDeskCoreChecks"

"$CHECK_BUILD_DIR/FocusDeskCoreChecks"
