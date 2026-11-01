## FocusDesk 3.0.0

原生 macOS 与 Windows 桌面专注挂件，中英文界面可切换。各设备独立保存个人数据，不含手机端或网络同步。

### 下载 / Downloads

| System | 中文默认 | English default |
|---|---|---|
| macOS 13+ Apple Silicon | `macos-arm64-zh-Hans.zip` | `macos-arm64-en.zip` |
| Windows 10/11 x64 | `windows-x64-zh-Hans.zip` | `windows-x64-en.zip` |

Both language editions have the same features. Change language in Settings; existing personal content is never translated or overwritten.

### New

- Native Windows desktop square, hover panel, tray, plan editing, confirmed conflict replacement, daily completion history, activity timers and totals.
- Complete English UI resources, including errors, examples, theme names, and quote explanations; 407 shared translations.
- Persistent silent countdown reminders, finish / five more minutes, accurate pause and restart accounting.
- Eleven palettes, ten completion effects, intensity settings and preview on both desktops. Effects preserve keyboard focus and pass clicks through.
- Shared resource validation, Mac XCTest, Windows behavioral checks, and actual Windows UI rendering in GitHub Actions.

### Installation and platform notes

Extract the complete Windows folder and run `FocusDesk.exe`; .NET is included. On Mac, move the extracted app to Applications. Quit the previous version and back up local data first.

Mac packages use ad-hoc signatures and are not Apple notarized. Windows packages are community builds without commercial code-signing certificates. SHA-256 checksums are attached.

Native platform behavior differs: Mac has inline drafts and history date filters; Windows uses edit dialogs and lists all historical days. Effects are rendered by each platform's native engine. Windows automated rendering does not cover every real hardware/DPI configuration. See the bilingual README for the full parity table and data locations.
