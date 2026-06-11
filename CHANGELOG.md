# Changelog

All notable changes to Bough are documented here.

## [v1.0.6] - 2026-06-10

### English

Expanded session list rendering fixes.

- Fixed the expanded panel showing no sessions at all when the session count exceeded "Max visible sessions": the list's scroll container reported no intrinsic height to SwiftUI and collapsed to zero.
- Fixed the expanded session list clipping at the bottom window edge when the session count was at or below "Max visible sessions": the full list now always renders inside a scroll container sized to the measured content height and capped to the available panel height.

### 简体中文

展开 session 列表渲染修复。

- 修复 session 数量超过「最大可见 session 数」时展开面板完全不显示 session 的问题：列表滚动容器未向 SwiftUI 提供内在高度，被压缩为零。
- 修复 session 数量不超过「最大可见 session 数」时展开列表底部被窗口边缘裁切的问题：完整列表现在始终在滚动容器内渲染，高度按实际内容测量并以可用面板高度为上限。

## [v1.0.5] - 2026-06-09

### English

Security hardening, broader CLI integrations, and reliability fixes.

- Hardened local data handling: `~/.bough` files and the usage SQLite store are now user-private (0700/0600), socket cleanup refuses to delete non-Bough files, and shell/SSH command construction quotes all untrusted values.
- Made permission handling fail closed: hidden plugin mode no longer auto-allows requests, and unanswerable permission prompts deny instead of allow.
- Added Kiro, Cursor CLI, and Qoder CLI session sources, plus custom CLI registration with rollback on hook install failure.
- Allowed Claude Code hooks and the statusLine bridge to coexist, with JSONC settings support and a stable bridge copy under `~/.bough`.
- Added multi-select answers for AskUserQuestion prompts and scoped permission queues per session to stop cross-session tool-use collisions.
- Fixed Claude project directory encoding (every non-alphanumeric character maps to `-`), restoring transcript discovery for paths containing dots.
- Fixed an AppState teardown crash when the last reference was released off the main thread.
- Improved usage monitoring: stale or future-dated samples are quarantined, threshold notifications survive restarts, and corrupt-store repair preserves WAL sidecars.
- Hardened the release pipeline: signing now fails closed without a Developer ID identity, DMG assets are version-named, and generated files are blocked from release artifacts.

### 简体中文

安全加固、更广的 CLI 集成与可靠性修复。

- 加固本地数据处理：`~/.bough` 文件与用量 SQLite 存储改为用户私有权限（0700/0600），socket 清理拒绝删除非 Bough 文件，shell/SSH 命令构造对所有不可信值加引号。
- 权限处理改为 fail-closed：隐藏插件模式不再自动放行请求，无法应答的权限弹窗按拒绝处理而非放行。
- 新增 Kiro、Cursor CLI、Qoder CLI 会话源，并支持自定义 CLI 注册（hook 安装失败时自动回滚）。
- Claude Code hooks 与 statusLine bridge 可共存，支持 JSONC 设置文件，并在 `~/.bough` 下使用稳定的 bridge 副本。
- AskUserQuestion 支持多选答案；权限队列按会话隔离，消除跨会话 tool-use 冲突。
- 修复 Claude 项目目录编码（所有非字母数字字符映射为 `-`），含点路径的 transcript 发现恢复正常。
- 修复最后引用在非主线程释放时 AppState 析构崩溃的问题。
- 改进用量监控：隔离过期或未来时间戳的样本，阈值通知在重启后仍可送达，损坏存储修复时保留 WAL 附属文件。
- 加固发布流水线：缺少 Developer ID 证书时签名直接失败，DMG 资产带版本号命名，并阻止生成文件混入发布产物。

## [v1.0.4] - 2026-06-04

### English

Homebrew Cask distribution and update ownership.

- Added Homebrew Cask as a primary install path through `DGPisces/tap`.
- Kept the visible GitHub Release DMG as the shared artifact for Homebrew and manual installs.
- Added Homebrew-managed update behavior so cask installs do not trigger Sparkle checks and show copyable Homebrew update commands.
- Added release automation that opens a manual-review PR against `DGPisces/homebrew-tap` with the verified DMG SHA-256.
- Fixed expanded panel height so long session lists scroll internally instead of clipping below the visible screen.

### 简体中文

Homebrew Cask 分发和更新归属。

- 新增通过 `DGPisces/tap` 安装的 Homebrew Cask 主要安装方式。
- 保持 GitHub Release 页面可见 DMG 作为 Homebrew 和手动安装共用的发布 artifact。
- 新增 Homebrew 管理更新行为：cask 安装版不触发 Sparkle 检查，并显示可复制的 Homebrew 更新命令。
- 新增 release 自动化：使用已验证的 DMG SHA-256 向 `DGPisces/homebrew-tap` 打开人工审核 PR。
- 修复展开面板高度，长 session 列表改为内部滚动，避免超出可见屏幕。

## [v1.0.3] - 2026-06-04

### English

Release rebuild hotfix for the public Settings appearance.

- Rebuilt release artifacts with the macOS 26 SDK while keeping the minimum runtime at macOS 14.0.
- Moved release and packaged smoke workflows to macOS 26 runners so signed public DMGs match the Settings appearance verified before release.
- Added release gates that reject DMGs without the AppKit Settings entry or with a macOS SDK older than 26.0.
- Added a post-publish GitHub asset verification step that downloads the published DMG and re-runs the release verification gates.

### 简体中文

公开版设置界面外观的重新构建 hotfix。

- 使用 macOS 26 SDK 重新构建 release artifact，同时保持最低运行系统为 macOS 14.0。
- 将 release 和 packaged smoke workflow 移到 macOS 26 runner，确保正式签名 DMG 与发布前验证的设置界面外观一致。
- 新增 release gate，拒绝不使用 AppKit 设置入口或 macOS SDK 低于 26.0 的 DMG。
- 新增发布后 GitHub asset 验证步骤：下载已发布 DMG，并重新运行 release verification gates。

## [v1.0.2] - 2026-06-04

### English

Settings hotfix for the signed public release.

- Removed the SwiftUI Settings scene that could surface a second, incorrectly laid-out Settings window in the signed release app.
- Moved app startup to an AppKit entry point so the app menu, Command-comma shortcut, and status menu all route to the same `SettingsWindowController` window.
- Verified the packaged app path with an isolated GUI smoke: the app menu and Command-comma each opened a single `Bough Settings` window at `660x540`.

### 简体中文

正式签名发布包的设置界面 hotfix。

- 移除 SwiftUI Settings scene，避免签名 release app 打开第二个排版错误的设置窗口。
- 将 app 启动入口迁移到 AppKit，让 app menu、Command-comma 快捷键和状态栏菜单都进入同一个 `SettingsWindowController` 窗口。
- 已用隔离 GUI smoke 验证打包 app 路径：app menu 和 Command-comma 都只打开一个 `660x540` 的 `Bough Settings` 窗口。

## [v1.0.1] - 2026-06-04

### English

Stable update that makes `v1.0.0-rc.1` installations see an available update.

- Bumped the app bundle metadata to `1.0.1` with build `2`, so Sparkle treats this release as newer than `v1.0.0-rc.1` and `v1.0.0` build `1`.
- Added release tooling to bump `Platform/Apple/Info.plist` from the latest stable update feed build.
- Added a release gate that rejects tags whose build number is not newer than the current stable update feed build.

### 简体中文

稳定版更新，让 `v1.0.0-rc.1` 安装包可以检测到可用更新。

- 将 app bundle metadata 升到 `1.0.1`，build 升到 `2`，让 Sparkle 将本次发布识别为比 `v1.0.0-rc.1` 和 `v1.0.0` build `1` 更新。
- 新增 release tooling，可根据最新 stable update feed build 自动更新 `Platform/Apple/Info.plist`。
- 新增 release gate，拒绝 build 号不高于当前 stable update feed build 的 tag。

## [v1.0.0] - 2026-06-03

### English

Stable release for Bough.

- Promoted release metadata and documentation from `v1.0.0-rc.1` to stable `v1.0.0`.
- Updated Sparkle to `2.9.2` for the stable candidate.
- Added English and Chinese README language-switch links.
- Verified build, tests, version consistency, packaging, installed-app smoke, usage smoke, AirDrop UAT, and P0/P1 triage before release closeout.

### 简体中文

Bough 稳定版发布。

- 将 release metadata 和文档从 `v1.0.0-rc.1` 提升到稳定版 `v1.0.0`。
- 将 Sparkle 更新到 `2.9.2`，用于稳定版候选构建。
- 新增英文和中文 README 语言切换入口。
- 发布收尾前已通过 build、tests、版本一致性、打包、已安装应用 smoke、用量 smoke、AirDrop UAT 和 P0/P1 triage。

## [v1.0.0-rc.1] - 2026-06-02

### English

Initial prerelease candidate for Bough.

- Added macOS notch status surfaces for supported AI coding tools.
- Added Bough mascot and supported-tool mascot presentation.
- Added usage, music, lyrics, AirDrop, diagnostics, and Settings preview surfaces.
- Added GitHub Releases DMG install path.
- Added stable-channel automatic update configuration for future stable builds.
- Prerelease builds may require manual updates from GitHub Releases.

### 简体中文

Bough 初始预发布候选版。

- 新增支持的 AI 编码工具 macOS 刘海状态界面。
- 新增 Bough mascot 和支持工具 mascot 展示。
- 新增用量、音乐、歌词、AirDrop、诊断和设置页预览界面。
- 新增 GitHub Releases DMG 安装路径。
- 新增未来稳定版构建使用的 stable channel 自动更新配置。
- 预发布构建可能需要从 GitHub Releases 手动更新。
