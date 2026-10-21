# FocusDesk

[简体中文](README.md) | **English**

A native desktop focus planner for Apple Silicon Macs, built with Swift, SwiftUI, AppKit, and local JSON storage. Requires macOS 13 or later. No server, database, or third-party dependencies.

The app interface and built-in schedule are currently in Simplified Chinese. This document provides English usage and development instructions.

## Screenshots

### Floating panel and settings

The floating panel shows your current task, remaining time, and next task. Settings let you control always-on-top behavior and launch at login.

| Floating panel | Settings |
| :---: | :---: |
| <img src="docs/screenshots/floating.png" alt="FocusDesk floating panel showing the current task, countdown, progress, and next task" width="320"> | <img src="docs/screenshots/settings.png" alt="FocusDesk settings for always-on-top behavior and launch at login" width="352"> |

### Today's plan

Browse your full schedule in chronological order. Click a task card or its pencil icon to edit it in place. Saving immediately updates the floating panel.

<img src="docs/screenshots/plan.png" alt="FocusDesk daily plan with browsing, editing, adding, and deleting tasks in one window" width="900">

## Usage

- On launch, the floating panel appears in the upper-right corner of the screen. Drag an empty area to move it; its position is saved.
- The panel displays the current time block, task title, detailed instructions, remaining time, progress, and next task. Unscheduled periods appear as “自由时间” (Free time).
- Click “今日计划” (Today's plan) to browse the full schedule in one scrollable window. Click a task card or pencil icon to turn that card into an inline editor. Change the start time, end time, title, or details, then click “完成并保存” (Save changes), or press ⌘S. Changes are saved locally and immediately reflected in the panel.
- Add and delete tasks in the same window. Browsing and editing do not use separate pages or editor windows.
- Enter times in 24-hour `HH:mm` format. The end must be later than the start. For a task starting after midnight, an end time of `00:00` means the end of that day (`24:00`). Zero-length blocks, overlapping tasks, and blank titles are rejected. Adjacent blocks may share a boundary. Split other overnight tasks at midnight.
- The schedule repeats daily. First launch includes 28 default tasks covering study, development, meals, exercise, rest, and sleep, including `00:00–08:00` for sleep and `23:00–00:00` for winding down.
- Use the timer icon in the menu bar to show or hide the panel, open the plan or settings, or quit. FocusDesk has no Dock icon and keeps running after you close the plan window.
- Settings include “悬浮窗始终置顶” (Always on top) and “登录 macOS 时启动” (Launch at login). The panel does not take keyboard focus. The app activates when you explicitly open the plan or settings window.

Task timing uses the actual system clock rather than counting timer ticks. It recalculates after wake, date changes, time-zone changes, and system-clock changes. Tasks repeat in local time. During free time, the panel shows the next task, including tomorrow's first task when appropriate.

## Run from Xcode

1. Install the full Xcode 15 or later and open `FocusDesk.xcodeproj`.
2. Select the **FocusDesk** scheme and **My Mac** as the run destination.
3. Run with ⌘R. If signing requires configuration, choose your development team under the target's **Signing & Capabilities**, or select **Sign to Run Locally** for local development.
4. Run unit tests with **Product → Test** (⌘U). The shared scheme includes `FocusDeskTests`.

The project uses Swift 5 language mode and can be built with a newer Swift compiler. It does not download external Swift packages. `Package.swift` exists only for independent testing of scheduling and validation logic; run the desktop app from the `.xcodeproj`.

## Build an .app

### With full Xcode

Choose **Product → Archive** in Xcode and export a macOS app through Organizer, or run this from the project root:

```sh
mkdir -p build/tmp
TMPDIR="$PWD/build/tmp/" xcodebuild \
  -project FocusDesk.xcodeproj \
  -scheme FocusDesk \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/build/DerivedData" \
  CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache" \
  CODE_SIGN_IDENTITY=- build
```

The output is `build/DerivedData/Build/Products/Release/FocusDesk.app`. Open it locally or copy it to Applications. Distribution to other users requires appropriate signing and notarization with your own Developer ID.

### With Command Line Tools only

The repository includes a script that builds directly with the system Swift compiler, targeting the arm64 architecture used by the MacBook Air M1:

```sh
./scripts/build-app.sh Release
```

Outputs are `build/Release/FocusDesk.app` and `build/Release/FocusDesk.zip`. The script applies an ad-hoc signature for local use and verifies it before packaging. The ZIP omits Finder extended attributes. The script builds without launching the app. For a debug build, use `./scripts/build-app.sh Debug`.

In the original development environment, the project was in a synced Desktop folder. Its file provider was observed reattaching `com.apple.FinderInfo` to the `.app` after signing, affecting later signature checks. If this happens, extract `FocusDesk.zip` into a folder outside sync, such as Applications, before running it. The script clears extended attributes only from generated project output; it does not change file-provider or system settings.

Launch at login uses macOS `SMAppService.mainApp`. Move the app to a stable location in Applications before enabling it. If macOS requires approval, allow FocusDesk under **System Settings → General → Login Items**. Building the app does not register a login item.

## Testing

Tests cover task matching, exact boundaries, the next task across midnight, remaining time and progress, free time, input formats, conflicting time blocks, and default-schedule integrity.

With full Xcode:

```sh
mkdir -p build/tmp
TMPDIR="$PWD/build/tmp/" xcodebuild \
  -project FocusDesk.xcodeproj \
  -scheme FocusDesk \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/build/DerivedData" \
  CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache" \
  CODE_SIGN_IDENTITY=- test
```

You can also run the core unit tests through Swift Package Manager:

```sh
mkdir -p build/tmp
TMPDIR="$PWD/build/tmp/" \
CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache" \
SWIFT_MODULECACHE_PATH="$PWD/build/ModuleCache" \
swift test --disable-sandbox \
  --scratch-path build/swift-test \
  --cache-path build/PackageCache \
  --config-path build/PackageConfig \
  --security-path build/PackageSecurity \
  --manifest-cache local
```

A Command Line Tools installation may lack XCTest. The app can compile in that environment, but `xcodebuild` and XCTest require full Xcode. A test blocked by that limitation has not passed.

For a Foundation-based check without XCTest, run:

```sh
bash scripts/check-core.sh
```

This script compiles the production core files and checks scenarios corresponding to the unit tests, including task matching, remaining time, cross-day behavior, and conflicts. Caches and output stay inside the project's `build/` directory. These checks do not replace XCTest or UI acceptance testing. The shared Xcode scheme isolates test data in `build/XCTestData` and uses in-memory preferences to avoid overwriting your regular plan.

Run `bash scripts/check-native.sh` for isolated native-window and persistence checks. It uses project-local test data and in-memory preferences, without launching your regular app or registering a login item. Window previews are saved to `build/native-smoke/`. This check requires a desktop session with WindowServer access; a restricted sandbox may block it. Switching apps, dragging the panel, and actual sleep/wake behavior still need manual verification in normal use.

To compile the native checks without creating windows, use `bash scripts/check-native.sh --build-only`.

### Recorded verification (2026-10-21)

- Swift 6.3.3 in Swift 5 language mode successfully compiled the arm64 app. Release `.app` and ZIP packaging succeeded. The archive contained no Finder metadata, matched the app's files, and passed code-signature verification after extraction.
- Foundation core checks: 20 scenarios, 124 assertions, 0 failures.
- Isolated native checks passed for launch without activating the app or taking focus, NSPanel configuration, visibility and always-on-top changes, plan/settings window reuse, persistence and reload, rejected edits leaving files unchanged, deletion, and corrupt-JSON backups. Three window previews were visually inspected.
- `xcodebuild build` and `xcodebuild test` were attempted. The machine had only Command Line Tools, without full Xcode or XCTest, so XCTest could not run. The Foundation and native checks are reported separately from XCTest.
- Regular login items, manual dragging across applications, and actual sleep/wake were not exercised. Those behaviors still require verification in normal use.

## Data

The first normal launch creates:

```text
~/Library/Application Support/FocusDesk/plan.json
```

Tasks are written atomically as JSON. The panel position and always-on-top preference use the app's `UserDefaults` domain, with bundle identifier `com.focusdesk.FocusDesk`. macOS stores the login-item state. Restarting restores the plan, position, and settings. If JSON cannot be loaded, the app preserves a timestamped backup in the same directory and displays a warning. If backup fails, saving is blocked to protect the original file.

During development, set `FOCUSDESK_DATA_DIRECTORY` to override the plan directory. This changes only the JSON location; regular UI preferences still use the app's `UserDefaults`. Build and core-test commands do not need to launch the GUI. Repository scripts keep compiler caches and temporary files inside the project's `build/` directory.

## Project structure

```text
FocusDesk/
  App/             App entry point, NSPanel, menu bar, and management windows
  Models/          Task model, time parsing and validation, default schedule
  Services/        Scheduling, local persistence, and system integration
  Views/           Floating panel, plan list with inline editing, settings
  Resources/       Info.plist
FocusDeskTests/    XCTest unit tests
FocusDesk.xcodeproj/
Package.swift      Standalone core-test entry point
scripts/          Local app build and verification scripts
docs/screenshots/ README screenshots
```
