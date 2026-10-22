# FocusDesk

**简体中文** | [English](README.en.md)

[![macOS CI](https://github.com/whathaventggood/FocusDesk/actions/workflows/ci.yml/badge.svg)](https://github.com/whathaventggood/FocusDesk/actions/workflows/ci.yml)

面向 Apple Silicon Mac 的原生桌面专注管理应用，使用 Swift、SwiftUI、AppKit 和本地 JSON。最低系统为 macOS 13，不需要服务器、数据库或第三方依赖。

[下载安装](docs/INSTALL.md) · [版本记录](CHANGELOG.md) · [发布流程](docs/RELEASING.md) · [GitHub Releases](https://github.com/whathaventggood/FocusDesk/releases)

## 界面展示

### 桌面小方块

平时只保留一个小方块，默认边长 56 点。鼠标移入自动展开任务详情，移入详情区域会保持展开；离开方块和详情后自动收起。

<img src="docs/screenshots/compact.png" alt="FocusDesk 桌面小方块，支持悬停展开、拖动和调整大小" width="112">

### 任务详情与设置

| 展开的任务详情 | 设置 |
| :---: | :---: |
| <img src="docs/screenshots/floating.png" alt="FocusDesk 当前任务、倒计时、进度与下一项任务" width="320"> | <img src="docs/screenshots/settings.png" alt="FocusDesk 方块大小、置顶与登录时启动设置" width="352"> |

### 今日计划

按开始时间浏览全天任务，在同一窗口中原位编辑、新增、删除和标记完成。

<img src="docs/screenshots/plan.png" alt="FocusDesk 今日计划，在同一窗口浏览和编辑任务" width="900">

### 专注记录

按日期查看任务完成率和当天的任务快照。

<img src="docs/screenshots/history.png" alt="FocusDesk 专注记录，展示每日完成率与任务快照" width="900">

## 使用

- **桌面组件**：拖动方块移动位置，拖动右下角调节大小。默认 56 点，设置中可调为 32–112 点，位置和大小自动记忆。悬停展开不主动抢夺键盘焦点。
- **当前任务**：显示时间段、标题、详细说明、剩余时间、时间进度和下一项任务。未安排任务时显示“自由时间”；时间进度只代表时间流逝，不代表任务完成。
- **今日计划**：点击任务卡片或铅笔图标，在原位置修改时间、名称和说明，点击“完成并保存”（⌘S）保存并同步悬浮窗。新增、编辑、删除均在同一管理窗口完成。
- **新增冲突处理**：有空闲时段时优先填入可用时间；全天排满时也能打开新增表单。与已有任务冲突时列出受影响任务，允许修改时间，或确认替换占用时段；替换会保留原任务未被覆盖的前后片段。确认前不改动原计划。
- **今日完成情况**：在任务旁手动勾选完成或撤销，保存后重启仍保留。时间到了不会自动标记完成。
- **专注记录**：查看近 7 天、近 30 天或全部历史，展示每日完成率及任务快照。完成率为已手动完成的任务数 ÷ 计划任务总数，包含睡眠和休息任务；区间完成率按总任务数计算，不是每日百分比的简单平均。没有记录的日期不补记为零。
- **每日作息**：计划每天重复。当前日期的计划修改会同步到今日记录，过去日期的任务名称、时间和完成状态保留快照，不随新计划变化。跨日及睡眠唤醒后按实际本地日期和系统时间更新。
- **菜单栏**：可显示/隐藏桌面组件，打开今日计划、专注记录和设置，或退出。应用不占 Dock 图标，关闭管理窗口后继续在菜单栏运行。
- **设置**：开关始终置顶、登录时启动。登录启动使用 macOS 的 `SMAppService.mainApp`，需将应用放在固定目录后由用户主动开启。

时间使用 `HH:mm` 24 小时制。结束时间必须晚于开始时间；结束时间 `00:00` 表示当天结束（24:00）。禁止零时长、无效时间、空名称和未经确认的重叠时段；相邻任务可共用边界。首次启动内置 28 项学习与生活任务。

## 安装与更新

从 [Releases](https://github.com/whathaventggood/FocusDesk/releases) 下载 ZIP，核对该版本签名说明和 SHA-256，解压后将 `FocusDesk.app` 放入“应用程序”。首次打开、系统提示、更新和备份步骤见 [安装说明](docs/INSTALL.md)。

普通本地构建及 CI 预览使用临时签名（ad-hoc），**不等于 Developer ID 签名或 Apple 公证**。Release 页面会写明实际签名状态；不要仅凭版本号判断。仓库提供可选 Developer ID + 公证流程，证书尚未配置时仍可生成明确标注的社区构建草稿。

## 从 Xcode 运行

1. 安装完整 Xcode 15 或更新版本，首次打开并完成其组件安装。
2. 打开 `FocusDesk.xcodeproj`，选择 **FocusDesk → My Mac**，按 **⌘R**。
3. 若出现签名提示，将本机开发签名设为 **Sign to Run Locally**，或选择自己的开发团队。
4. 按 **⌘U** 运行共享 scheme 中的 `FocusDeskTests`。

工程使用 Swift 5 语言模式，目标系统 macOS 13。实际桌面应用从 `.xcodeproj` 运行；`Package.swift` 只用于无界面的模型与持久化逻辑测试。

## 构建与打包

只有 Command Line Tools 也可构建本机 arm64 应用：

```sh
./scripts/build-app.sh Release
```

输出 `build/Release/FocusDesk.app`、`FocusDesk.zip` 和 `SHA256SUMS.txt`。这是未公证的本地临时签名构建；脚本只构建，不启动应用，不注册登录项。

完整 Xcode 可先运行真正的 XCTest，再生成带版本号的候选包：

```sh
./scripts/package-release.sh
```

输出位于 `build/release/`，包含 `FocusDesk-2.1.0-arm64.zip`、SHA-256、安装说明和发布说明。测试不通过时不生成候选包。Xcode 的 **Product → Archive** 也可用于归档；对外分发的签名、公证与草稿发布步骤见 [发布流程](docs/RELEASING.md)。

## 测试与 CI

```sh
./scripts/test-xcode.sh
```

此脚本实际执行 `xcodebuild build test`，运行 app-hosted XCTest，保留 `build/TestResults/*.xcresult` 和日志。测试环境使用项目内的数据目录和内存偏好，避免覆盖日常使用的计划。只有 Command Line Tools 时脚本会明确失败，不会用其他检查冒充 XCTest。

测试覆盖时间匹配和边界、剩余时间、自由时间、跨日、输入校验、新增冲突替换、今日完成/撤销、日期切换、历史快照、旧版 JSON 迁移、原子保存与损坏文件保护。

GitHub Actions 对 `main` 推送、Pull Request 和手动触发执行同一 Xcode 测试，并保留结果包、日志和 arm64 预览 ZIP。正式候选包工作流由版本标签触发，测试成功后创建 **draft Release**，等待维护者审阅发布。工作流文件已加入仓库；**配置好 CI 不代表 CI 已运行通过**，请以 Actions 中对应提交的结果为准。

本机验证记录：Foundation 核心检查 27 个用例、151 项断言通过；原生窗口检查 112 项通过；arm64 Release 应用构建和签名校验通过。本机安装为 Command Line Tools，尚未具备完整 Xcode；本轮真实 XCTest 结果需由完整 Xcode 或推送后的 CI 补齐。这些辅助检查不替代 XCTest。

辅助检查仍可运行：

```sh
bash scripts/check-core.sh
bash scripts/check-native.sh
```

原生窗口检查需要可访问 WindowServer 的桌面会话；仅编译可用 `bash scripts/check-native.sh --build-only`。真实跨应用悬停、拖动、缩放和睡眠唤醒仍需手动验收。

## 数据与备份

```text
~/Library/Application Support/FocusDesk/plan.json
```

同一 JSON 文件原子保存重复作息和每日历史记录，包含数据格式版本。兼容旧版只含任务数组的 `plan.json`；首次保存时迁移，升级前建议备份，降级时需恢复旧版备份。当天修改同步到今日快照，历史日期快照保留。

若 JSON 无法读取，应用保留损坏文件备份并停止保存，显示具体恢复提示，避免静默覆盖历史。方块位置、大小和置顶偏好使用 `com.focusdesk.FocusDesk` 的 `UserDefaults`，登录项由系统保存。应用没有服务器，也不会上传计划。

开发可用 `FOCUSDESK_DATA_DIRECTORY` 指定数据目录。编译缓存、测试报告和脚本临时文件都位于项目 `build/` 内。备份与恢复详见 [安装说明](docs/INSTALL.md)。

## 工程结构

```text
FocusDesk/
  App/          应用入口、NSPanel、菜单栏与管理窗口
  Models/       任务、时间校验、冲突替换、每日完成快照
  Services/     时间匹配、JSON 原子存储与系统设置
  Views/        小方块、悬浮详情、原位计划编辑、历史与设置
  Resources/    Info.plist
FocusDeskTests/ XCTest
FocusDesk.xcodeproj/
Package.swift   独立逻辑测试入口
scripts/        构建、Xcode 测试与候选包脚本
.github/workflows/ CI 与草稿 Release
CHANGELOG.md
docs/          安装、发布说明与截图
```
