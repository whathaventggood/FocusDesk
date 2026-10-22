# FocusDesk 发布流程 / Release process

[返回 README](../README.md) · [Installation in English](INSTALL.md#english)

`v2.1.0` 是当前准备的版本号。仓库中的脚本和工作流只能准备候选包；是否通过 XCTest、是否经过 Apple 公证以及是否已经公开发布，均须查看实际运行结果。不要仅凭版本号或 README 徽章判断。

## 发布前核对

1. 在 `FocusDesk/Resources/Info.plist` 中设置 `CFBundleShortVersionString` 与递增的 `CFBundleVersion`，同步 `FocusDesk.xcodeproj` 的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`，更新 `CHANGELOG.md`。当前设置为版本 `2.1.0`、构建号 `3`。
2. 使用完整 Xcode 在 macOS 桌面会话中运行 `./scripts/test-xcode.sh`；该脚本执行 app-hosted XCTest，并把 `.xcresult` 和日志写入 `build/TestResults/`。只有 Command Line Tools 时会明确失败。
3. 检查 GitHub Actions 的 **macOS CI**：目标提交的 `build-and-test` 必须通过。检查 XCTest 报告和 arm64 预览包，并在真实 Mac 上手动验收悬停、跨应用显示、拖动、缩放、睡眠唤醒、编辑冲突和历史记录。
4. 核对 README、安装说明、截图和隐私数据处理。保存一份旧版 `plan.json` 以验证迁移；不要把个人计划文件提交到仓库。

本机有完整 Xcode 时，可先运行 `./scripts/package-release.sh`，它先执行相同的 XCTest，再构建 arm64 候选包、SHA-256、安装说明和发布说明。默认输出使用 ad-hoc 临时签名，**没有 Developer ID 签名，也没有 Apple 公证**。

## 使用标签生成 Release 草稿

将通过验证的提交合入 `main` 后，检查版本标签尚不存在，再由维护者执行：

```sh
git tag -a v2.1.0 -m "FocusDesk 2.1.0"
git push origin v2.1.0
```

标签必须与 `Info.plist` 的版本号一致。不要移动已发布的标签；如需修正发布内容，请递增版本与构建号。`Release candidate` 工作流在 Apple Silicon `macos-15` 运行真正的 XCTest；失败时不创建草稿。测试通过后，它构建、校验并上传 ZIP、`SHA256SUMS.txt` 和 `INSTALL.md`，随后创建 **draft Release**。草稿不会自动公开。

到仓库的 **Actions** 查看对应标签运行结果，再到 **Releases → Drafts** 检查附件和说明。下载 ZIP 及校验文件，用 `shasum -a 256 -c SHA256SUMS.txt` 核对，再在干净的 macOS 用户环境中验证安装和首次启动。维护者完成检查后，手动点击 **Publish release**。旧版项目尚未上传的工作流不能在 GitHub 运行；先推送包含工作流的提交才能取得真实 CI 结果。

## 签名与公证

未配置下列全部六项仓库级 Actions secrets 时，工作流生成明确标注 **ad-hoc、未公证** 的社区候选包。只配置其中一部分会使发布工作流失败，避免意外降级。建议用受保护的标签规则限制谁能触发发布。当前工作流读取仓库级 secrets；若改为环境级 secrets，还需给 release job 配置相应的 `environment`。

| Secret | 用途 |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Developer ID Application 证书及私钥导出的 `.p12` 文件，Base64 编码 |
| `DEVELOPER_ID_P12_PASSWORD` | `.p12` 密码 |
| `DEVELOPER_ID_IDENTITY` | 完整的 `Developer ID Application: ...` 签名身份 |
| `APPLE_ID` | 用于 Apple 公证的 Apple ID |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | 对应 Apple ID 的应用专用密码 |

六项齐全时，工作流会在临时 CI 钥匙串导入证书，以 Developer ID 和 hardened runtime 签名，向 Apple 公证服务提交，等待 **Accepted**，装订并验证票据，再重新打包。只有这些步骤全成功，草稿说明才写“Developer ID signed and Apple notarized”。签名材料只放在 GitHub Secrets 中，不提交到代码仓库；不要对不可信的标签或工作流改动开放发布凭据。

无 Developer ID 的包可能被 Gatekeeper 阻止；请按 [安装说明](INSTALL.md) 向使用者明确告知。不要把 ad-hoc 构建称为已公证版本，也不要建议关闭 Gatekeeper。

## English summary

Use full Xcode to run `./scripts/test-xcode.sh`, then check the exact commit's macOS CI result and test artifacts. Once validated, tag the matching version and push that tag. The release workflow runs XCTest again, packages an arm64 candidate, and creates a **draft** GitHub Release for manual inspection and publication. With no signing secrets it produces an explicitly labeled ad-hoc, unnotarized build. With all six credentials it must pass Developer ID signing, Apple notarization, stapling, and verification before creating the draft. Partial credentials fail the workflow. See [installation and backup instructions](INSTALL.md#english).
