# 安装、更新与备份 / Installation

[English](#english) · [返回 README](../README.md)

## 系统要求

- Apple Silicon Mac（M1、M2 或更新芯片），macOS 13 或更新版本。
- 下载的是 `arm64` 应用，目前没有提供 Intel 版本。
- 使用应用不需要 Xcode；从源码构建才需要开发工具。

## 安装

1. 在本仓库 [Releases](https://github.com/whathaventggood/FocusDesk/releases) 中选择版本，阅读签名状态，下载 `FocusDesk-版本号-arm64.zip`、`SHA256SUMS.txt`。旧版本附件可能叫 `FocusDesk.zip`。
2. 可选：把 ZIP 与校验文件放在同一目录，在该目录打开终端执行 `shasum -a 256 -c SHA256SUMS.txt`。显示 `OK` 表示文件与校验记录一致；校验和本身不能证明发布者身份。
3. 双击 ZIP 解压，把 `FocusDesk.app` 拖入“应用程序”。先完成复制，再打开应用。
4. 启动后，查看屏幕右上角的小方块和菜单栏计时器图标。应用不显示 Dock 图标。
5. 想开机启动时，在 FocusDesk 设置中主动开启“登录时启动”。若系统要求批准，按系统提示操作。

### macOS 首次打开提示

请核对 Release 中的签名说明。`ad-hoc` 表示本地临时签名，不能验证开发者身份，也没有经过 Apple 公证。Developer ID + notarized 只用于真正完成相应流程的版本；旧版和 CI 预览不自动具备这些保证。

首次下载的应用可能出现“从互联网下载”的确认。对于未验证开发者提示，只在确定下载来源和内容可信时尝试 Finder 中右键应用 →“打开”；较新系统可能需先尝试启动，再到“系统设置 → 隐私与安全性”按系统提示选择“仍要打开”。界面是否提供该选项取决于系统版本和管理策略。参见 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。

如果提示应用已损坏或含恶意软件，停止安装，重新核对下载来源和 SHA-256，并向项目提交问题。不要关闭 Gatekeeper，也不要用删除隔离属性的命令绕过提示。

## 更新

1. 从菜单栏选择“退出 FocusDesk”，确认旧版本已退出。
2. 备份下面的数据文件。
3. 下载并核对新版，把新应用替换到“应用程序”。再次打开后计划、历史和设置继续使用原位置。
4. 从旧版本升级时，任务数组会迁移为包含计划和历史的版本化 JSON。降级旧版本前，恢复旧版兼容备份，避免用旧版本读取新格式。

## 备份与恢复

计划及历史位于同一文件：

```text
~/Library/Application Support/FocusDesk/plan.json
```

先退出应用。在 Finder 按 **⌘⇧G**，输入上面路径的父目录 `~/Library/Application Support/FocusDesk`，复制 `plan.json` 到自己选定的备份位置。恢复时先退出应用，把备份复制回原位置，再打开。文件中可能包含私人任务说明，请自行妥善保存。

损坏文件会在同目录保留 `plan.corrupt-*.json` 备份，并阻止继续保存。优先恢复可读备份；没有备份且愿意清空现有计划与历史时，可在设置中使用显式恢复默认功能并确认。恢复默认需要先成功备份原文件，失败时不会覆盖。

方块位置、大小和置顶偏好由系统 `UserDefaults` 保存，单独备份 `plan.json` 不含这些界面偏好；登录项由 macOS 管理。

## 卸载

先在应用设置中关闭登录时启动，再从菜单栏退出应用，把 `FocusDesk.app` 移到废纸篓。删除应用不会自动删除计划及历史；需要清除时，请先备份，再由自己删除上述数据目录。

## English

### Requirements

Apple Silicon Mac (M1 or later), macOS 13 or later. Downloads contain arm64 builds; Intel builds are not provided. Xcode is only needed for development.

### Install and verify

1. Open [Releases](https://github.com/whathaventggood/FocusDesk/releases), read the signing disclosure, and download `FocusDesk-VERSION-arm64.zip` and `SHA256SUMS.txt`. Older releases may use `FocusDesk.zip`.
2. Optionally place both files together and run `shasum -a 256 -c SHA256SUMS.txt` in that directory. `OK` verifies integrity against the supplied checksum, not the publisher's identity.
3. Extract the ZIP and move `FocusDesk.app` to Applications before launching.
4. Look for the desktop square and menu-bar timer; the app has no Dock icon.
5. Enable launch at login in FocusDesk Settings only if desired.

An ad-hoc build is not Developer ID signed or Apple notarized. A release only claims those properties when that specific artifact completed those steps. Read its release notes.

For first-launch alerts, follow the macOS confirmation. If an unidentified developer is reported, only after verifying trust in the source, try Finder → right-click → Open. On newer systems, first attempt launch, then follow System Settings → Privacy & Security → Open Anyway if offered. Availability depends on the OS and management policy. See [Apple's official guidance](https://support.apple.com/en-us/102445).

For damaged-app or malware alerts, stop and verify the source and checksum. Do not disable Gatekeeper or strip quarantine attributes to bypass a warning.

### Update, back up, and recover

Quit FocusDesk from its menu bar, back up `~/Library/Application Support/FocusDesk/plan.json`, then replace the app in Applications. Plans, completion history, and preferences persist.

The JSON contains private task details. Quit before copying or restoring it. In Finder, **⌘⇧G** opens `~/Library/Application Support/FocusDesk`; copy `plan.json` to your chosen backup location. Restore a known-good copy there before restarting.

Earlier task-array files migrate to a versioned plan-and-history document on saving. Downgrading requires a backup compatible with the old app. Window preferences are stored separately in UserDefaults, and login items are managed by macOS.

Unreadable files are preserved as `plan.corrupt-*.json` and further saves stop. Restore a good backup first. Settings also offers an explicit, confirmed reset to defaults, which clears the current plan and history only after successfully backing up the unreadable source.

To uninstall, disable launch at login, quit from the menu bar, and remove the app. Data remains until you choose to remove the data directory after backup.
