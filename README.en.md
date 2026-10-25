# FocusDesk

[简体中文](README.md) | **English**

[![macOS CI](https://github.com/whathaventggood/FocusDesk/actions/workflows/ci.yml/badge.svg)](https://github.com/whathaventggood/FocusDesk/actions/workflows/ci.yml)

A native desktop focus manager for Apple Silicon Macs, built with Swift, SwiftUI, AppKit, and local JSON storage. Requires macOS 13 or later. No server, database, or third-party dependencies. The app interface and built-in schedule are currently in Simplified Chinese.

[Installation](docs/INSTALL.md#english) · [Changelog](CHANGELOG.md) · [Release process](docs/RELEASING.md) · [GitHub Releases](https://github.com/whathaventggood/FocusDesk/releases)

## Screenshots

### Desktop square

A small 56-point square stays on the desktop. Hover to expand a 360 × 500-point task details panel, move into the details to keep them open, and move outside both areas to collapse. “一点鼓励” (A little encouragement) at the bottom displays a short quote.

<img src="docs/screenshots/compact.png" alt="FocusDesk desktop square with hover expansion, dragging, and resizing" width="112">

### Task details and settings

| Expanded task details | Settings |
| :---: | :---: |
| <img src="docs/screenshots/floating.png" alt="Current task, remaining time, progress, and next task" width="320"> | <img src="docs/screenshots/settings.png" alt="Square size, always on top, and launch at login settings" width="352"> |

### Today's plan

Browse the full day in start-time order. Edit, add, delete, and mark tasks complete in the same window.

<img src="docs/screenshots/plan.png" alt="Today's plan with viewing and editing in the same window" width="900">

### Focus history

Review completion rates by date and each day's task snapshot.

<img src="docs/screenshots/history.png" alt="FocusDesk history showing daily completion rates and task snapshots" width="900">

## Usage

- **Desktop square:** drag to move, or drag the bottom-right corner to resize. The default size is 56 points; Settings allows 32–112 points. Size and position persist. Hover expansion does not take keyboard focus.
- **Current task:** shows its time range, title, details, remaining time, elapsed-time progress, and next task. Gaps show “自由时间” (free time). Elapsed-time progress is separate from completion.
- **A little encouragement:** the expanded panel randomly selects from 20 original Chinese quotes included with the app. The quote updates every six hours without consecutive repeats. Restarting within the same period preserves the quote; waking after a long sleep refreshes it according to the actual time. Quotes work offline.
- **Today's plan:** click a task card or pencil to edit its time, title, and details in place. “完成并保存” (save, ⌘S) persists the change and updates the desktop view. Viewing and editing share one management window.
- **Conflict handling:** new tasks prefer available gaps. A fully booked day still allows an empty-time draft. Overlaps list the affected tasks and available gaps. Change the time, use a suggested gap, or preview replacing the occupied interval while preserving uncovered portions of the original tasks. Replacement requires explicit confirmation before atomic saving.
- **Completion:** manually check or uncheck tasks; completion survives restart. Reaching an end time never automatically marks a task complete.
- **History:** inspect the last 7 days, 30 days, or all recorded days. Completion rate is completed task count divided by planned task count, including breaks and sleep. Range totals are weighted by total task count, rather than averaging daily percentages. Days without records are omitted rather than recorded as zero.
- **Daily schedule:** repeats each day. Today's edits update today's snapshot. Past task names, times, and completion states retain their snapshots. Day changes and wake events recalculate from the actual local date and system clock.
- **Menu bar:** show or hide the desktop component, open the plan, focus history, and settings, or quit. The app has no Dock icon and keeps running when management windows close.
- **Settings:** always on top and launch at login. Login startup uses `SMAppService.mainApp`; install the app in a stable location and enable it yourself.

Times use 24-hour `HH:mm` format. End time must be later than start time; an end of `00:00` means the end of the day (24:00). Zero duration, malformed time, empty titles, and unconfirmed overlaps are rejected. Adjacent tasks may share a boundary. First launch includes 28 study and daily-life tasks.

## Install and update

Download a ZIP from [Releases](https://github.com/whathaventggood/FocusDesk/releases), check that version's signing disclosure and SHA-256, extract it, and move `FocusDesk.app` into Applications. See [installation instructions](docs/INSTALL.md#english) for first launch, system warnings, updates, and backup.

Local builds and CI previews use **ad-hoc signing, which is not Developer ID signing or Apple notarization**. Each release discloses its actual status. Optional Developer ID signing and notarization are supported; without configured credentials, the workflow can prepare a clearly labeled community-build draft.

## Run from Xcode

1. Install full Xcode 15 or later, open it, and finish installing its components.
2. Open `FocusDesk.xcodeproj`, select **FocusDesk → My Mac**, and press **⌘R**.
3. If prompted about signing, choose **Sign to Run Locally** or your development team.
4. Press **⌘U** to run `FocusDeskTests` in the shared scheme.

The project uses Swift 5 language mode and targets macOS 13. Run the actual desktop app from `.xcodeproj`; `Package.swift` is only for headless model and persistence tests.

## Build and package

Command Line Tools can build the local arm64 app:

```sh
./scripts/build-app.sh Release
```

Outputs: `build/Release/FocusDesk.app`, `FocusDesk.zip`, and `SHA256SUMS.txt`. This is an ad-hoc signed, unnotarized local build. The script does not launch the app or register login items.

With full Xcode, run real XCTest and produce a versioned candidate:

```sh
./scripts/package-release.sh
```

Outputs in `build/release/` include `FocusDesk-2.2.0-arm64.zip`, SHA-256, installation instructions, and release notes. Failing tests prevent packaging. You can also archive through **Product → Archive**. See the [release process](docs/RELEASING.md) for distribution signing, notarization, and draft review.

## Tests and CI

```sh
./scripts/test-xcode.sh
```

This executes `xcodebuild build test` against the app-hosted XCTest target and preserves `build/TestResults/*.xcresult` and logs. Test environments use project-local data and in-memory preferences to protect everyday plans. With only Command Line Tools the script fails explicitly; smoke checks do not stand in for XCTest.

Tests cover time matching and boundaries, remaining time, free time, midnight, input validation, conflict replacement, completion and undo, date changes, historical snapshots, legacy JSON migration, atomic persistence, corrupt-file protection, and quote rotation across six-hour boundaries, restarts, sleep, clock corrections, and malformed caches.

GitHub Actions runs the same Xcode tests for `main` pushes, pull requests, and manual dispatches, retaining reports, logs, and an arm64 preview ZIP. A version tag triggers the release workflow; only successful tests allow creation of a **draft release**, which a maintainer reviews before publishing. Check the actual Actions result and XCTest report for the exact commit to confirm whether tests passed.

Foundation checks, native-window checks, and local app builds provide additional validation. They do not replace app-hosted XCTest run with full Xcode or in CI.

Optional checks:

```sh
bash scripts/check-core.sh
bash scripts/check-native.sh
```

Native checks require a desktop session with WindowServer access; use `bash scripts/check-native.sh --build-only` to compile without opening test windows. Cross-app hovering, dragging, resizing, quote display, and actual sleep/wake still need manual acceptance testing.

## Data and backup

```text
~/Library/Application Support/FocusDesk/plan.json
```

One versioned JSON document atomically stores the repeating plan and daily history. Legacy task-array files migrate on the first successful save. Back up before upgrading; downgrading requires restoring a compatible backup. Current-day edits reconcile today's snapshot, while past snapshots remain unchanged.

Unreadable data is backed up and saving stops with a recovery message, protecting history from silent replacement. Window position, size, and always-on-top preferences use the `com.focusdesk.FocusDesk` UserDefaults domain. macOS stores the login-item state. The quote and its refresh time are cached separately in UserDefaults without changing `plan.json`, tasks, or completion history. There is no server and plans are not uploaded.

Developers can set `FOCUSDESK_DATA_DIRECTORY` to override the JSON directory. Compiler caches, test reports, and script temporary files remain inside the project's `build/` directory. See [installation instructions](docs/INSTALL.md#english) for backup and recovery.

## Project structure

```text
FocusDesk/
  App/          Entry point, NSPanels, menu bar, and management windows
  Models/       Tasks, validation, conflict replacement, daily snapshots
  Services/     Scheduling, atomic JSON persistence, system integration
  Views/        Square, details, inline plan editor, history, settings
  Resources/    Info.plist
FocusDeskTests/ XCTest
FocusDesk.xcodeproj/
Package.swift   Headless logic-test entry point
scripts/        Build, Xcode test, and release-candidate scripts
.github/workflows/ CI and draft releases
CHANGELOG.md
docs/           Installation, release instructions, screenshots
```
