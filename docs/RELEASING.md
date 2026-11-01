# Desktop releases / 电脑端发布

Current release line: **3.1.0**, Mac build **8**, Windows .NET version **3.1.0**.

1. Run `python3 scripts/localization/generate.py`; commit both shared resources and generated Swift.
2. Update the versions in `Info.plist`, the Xcode project, Windows csproj, package filenames in workflows, README, and changelog together.
3. Push to a `codex/` branch. Wait for **Desktop parity**: actual Mac XCTest, actual Windows core checks, and Windows screenshot rendering must pass. Inspect the exact commit's artifacts and screenshots.
4. Update `docs/screenshots/` using actual render outputs; do not substitute mockups for real platform screenshots.
5. Merge or fast-forward the verified change to `main`, and verify the final commit's checks.
6. Create a new immutable version tag, e.g. `v3.1.0`. **Desktop release** runs the same required checks and publishes four language/platform ZIPs and `SHA256SUMS.txt` only after success.
7. Download the release assets, check filenames and SHA-256, and verify installation. Never move an existing published tag.

Mac community ZIPs use ad-hoc signatures and are not Apple notarized. Windows community ZIPs are unsigned and include the runtime. The historical `Release candidate` workflow is retained for `v2.*` tags only; do not use it for desktop 3.x releases.

Language editions differ only in initial language configuration. Personal files, environment-specific caches, signing credentials, and test data must never enter the release artifacts. Packaging uses build output only; screenshot smoke tests use isolated temporary directories.

个人数据只保存在各自设备上。发布不会上传本地计划、计时记录或用户偏好。所有 GitHub 凭据只由已有的登录会话或 Actions token 提供，不写入代码。
