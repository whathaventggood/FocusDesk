# Install / 安装

## 中文

从 [GitHub Releases](https://github.com/whathaventggood/FocusDesk/releases/latest) 选择系统与默认语言，下载 ZIP。两种语言包都能在设置里切换语言。

- **macOS 13+ / Apple Silicon**：解压，把 `FocusDesk.app` 放入“应用程序”。这是未公证的社区临时签名构建；若系统拦截，核对来源与 SHA-256 后，按 macOS“隐私与安全性”中针对该应用的提示决定是否允许。不要关闭 Gatekeeper。
- **Windows 10/11 x64**：完整解压文件夹，打开 `FocusDesk.exe`。运行时已包含，无需安装 .NET。不要只复制 EXE。首次使用可通过系统托盘打开计划、计时与设置。社区构建没有商业发布者签名，Windows 可能要求确认来源。
- 升级前通过菜单栏或托盘退出旧版。备份下面的数据，再替换应用；不要把旧应用文件夹里的用户自建文件误删。
- 登录时启动在设置中主动开启。Windows 开启后请保持 EXE 路径固定；移动应用前先关闭该设置。

数据备份：Mac 退出后复制 `~/Library/Application Support/FocusDesk/`；Windows 退出后复制 `%LOCALAPPDATA%\FocusDesk\`。损坏文件恢复前保留原件和 `.corrupt-*` 备份。系统间格式不同，不要互相替换 JSON。

## English

Choose your OS and default language from [GitHub Releases](https://github.com/whathaventggood/FocusDesk/releases/latest). Both editions allow switching languages in Settings.

- **macOS 13+ / Apple Silicon:** extract and move `FocusDesk.app` to Applications. Community builds are ad-hoc signed, not Apple notarized. If blocked, verify the source and checksum, then use the app-specific options offered in macOS Privacy & Security. Do not disable Gatekeeper.
- **Windows 10/11 x64:** extract the complete folder and launch `FocusDesk.exe`. The runtime is included. Do not copy the EXE alone. Use the system tray for Plan, Timers, and Settings. Community builds have no commercial publisher signature; Windows may ask you to verify the source.
- **Upgrade:** quit the old app from its menu bar/tray, back up data, then replace application files.
- **Launch at login:** opt in through Settings. Keep the executable in a fixed location; disable launch at login before moving it.

Back up `~/Library/Application Support/FocusDesk/` on Mac or `%LOCALAPPDATA%\FocusDesk\` on Windows while the app is closed. Keep original damaged files and corruption backups before restoring. The platforms use different JSON formats; do not replace one platform's files with the other's.

Verify release downloads with `shasum -a 256 -c SHA256SUMS.txt` on Mac, or compare `Get-FileHash <file.zip> -Algorithm SHA256` against the checksum file in PowerShell.
