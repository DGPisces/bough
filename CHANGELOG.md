# Changelog

All notable changes to Bough are documented here.

## [v1.2.3] - 2026-08-01

### English

Bough approvals can now be disabled in favor of native CLI approval, and long approval details no longer hide the action buttons.

**Approvals — Added:**

- A new setting lets you turn Bough approval prompts on or off. When off, Codex and Claude Code use their own approval interface; existing behavior remains the default.

**Approvals — Fixed:**

- Long commands and approval details now scroll within the approval card, keeping Deny, Dismiss, Allow Once, and Always visible and usable.

### 简体中文

Bough 审批现在可以关闭并回退到 CLI 原生审批，超长审批内容也不再遮挡操作按钮。

**审批 — 新增：**

- 新增 Bough 审批开关。关闭后，Codex 和 Claude Code 使用各自的原生审批界面；默认仍保持现有 Bough 审批行为。

**审批 — 修复：**

- 长命令和审批详情现在可在审批卡片内滚动，拒绝、忽略、允许一次和始终允许按钮始终可见并可操作。

## [v1.2.2] - 2026-07-17

### English

Fixes Codex "Approve for me" so Codex reviews requests before Bough asks for human approval.

**Approvals — Fixed:**

- Bough now recognizes Codex's compatible `guardian_subagent` reviewer value as auto-review, alongside `auto_review`. Permission requests are deferred to Codex's native reviewer instead of opening Bough's human approval prompt first.

### 简体中文

修复 Codex“Approve for me”：现在由 Codex 先审批，不再由 Bough 先弹出人工审批。

**审批 — 修复：**

- Bough 现在将 Codex 的兼容值 `guardian_subagent` 与 `auto_review` 一样识别为自动审批。权限请求会交回 Codex 原生审批器，不再先打开 Bough 人工审批弹窗。

## [v1.2.1] - 2026-07-14

### English

Actually eliminates the Claude keychain authorization dialog — the v1.2.0 fix did not work.

**Usage — Fixed:**

- The "Bough wants to access key Claude Code-credentials" dialog is gone for real. v1.2.0's non-interactive read did not suppress the legacy authorization dialog — it blocked on the dialog instead of failing silently, and because it ran first, the reliably-silent `/usr/bin/security` read never got a chance. The silent path now goes straight through `/usr/bin/security` (which the item's ACL trusts, so it never prompts); an in-process read that can prompt is used only when you explicitly retry from Settings.
- Verified on a signed build: usage refreshes silently on every poll with no dialog.

### 简体中文

真正消除 Claude 钥匙串授权弹窗——v1.2.0 的修复实际无效。

**用量 — 修复：**

- "Bough 想访问钥匙串 Claude Code-credentials"弹窗这次真的消失了。v1.2.0 的非交互读取并不能压制旧式授权对话框——它会**卡在弹窗上**而不是静默失败，且因为排在最前，那个真正静默的 `/usr/bin/security` 读取永远没机会执行。现在静默路径直接走 `/usr/bin/security`（该条目 ACL 信任它，永不弹窗）；会弹窗的进程内读取只在你从设置里主动重试时才使用。
- 已在签名构建上验证：每个轮询周期都静默刷新用量，无任何弹窗。

## [v1.2.0] - 2026-07-13

### English

Zero-prompt Keychain access for the Claude usage channel, plus delegated token refresh.

**Usage — Fixed:**

- The macOS Keychain authorization dialog for "Claude Code-credentials" is gone for good. The Claude CLI stores its credentials with a partition list that third-party apps can never satisfy, so any in-process read prompted on every token rotation — even after "Always Allow". Keychain reads now use a non-interactive authorization context and fall back to a silent `/usr/bin/security` read (approach adapted from [CodexBar](https://github.com/steipete/CodexBar)); background refreshes can no longer show a dialog at all.
- A transient Keychain read failure no longer silences the usage channel for 6 hours: the quiet period now applies only when a real authorization dialog is actually denied.

**Usage — Added:**

- Delegated token refresh: when the Claude CLI token expires while the CLI is idle, Bough briefly launches `claude` so the CLI renews its own credentials — verified via the Keychain item fingerprint and rate-limited with cooldowns. Usage data now self-heals instead of going stale until your next Claude session.
- The background usage monitor reads rotated tokens itself after its token mirror expires, so background-only operation (app closed) keeps working across token rotations.

### 简体中文

Claude 用量通道钥匙串访问零弹窗，并新增委托令牌刷新。

**用量 — 修复：**

- "Claude Code-credentials" 的 macOS 钥匙串授权弹窗彻底消失。Claude CLI 写入凭据时的分区表第三方应用永远无法命中，因此进程内读取在每次令牌轮换时都会弹窗——即使点过"始终允许"。钥匙串读取现改用非交互授权上下文，并以静默的 `/usr/bin/security` 读取兜底（方案移植自 [CodexBar](https://github.com/steipete/CodexBar)）；后台刷新从此不可能再弹出对话框。
- 钥匙串读取的瞬时失败不再让用量通道静默 6 小时：静默期现在只在真实授权弹窗被拒绝时生效。

**用量 — 新增：**

- 委托令牌刷新：Claude CLI 令牌过期且 CLI 空闲时，Bough 会短暂启动 `claude` 让 CLI 自行续期——以钥匙串条目指纹变化为成功判据，并有冷却限速。用量数据从此自愈，不再"等你下次用 Claude 才恢复"。
- 后台用量监控在令牌镜像过期后可自行读取轮换后的新令牌，App 关闭时的纯后台运行跨令牌轮换持续工作。

## [v1.1.1] - 2026-07-06

### English

Fixes the recurring Keychain authorization dialog and the notch expand flicker.

**Usage — Fixed:**

- The macOS Keychain dialog for "Claude Code-credentials" no longer reappears on every usage refresh. Bough now caches the token until it expires and, before reading again, checks the Keychain item's modification date — an operation that never prompts — so an unchanged item is never re-read. After a single "Allow", normal use stays prompt-free even without "Always Allow".
- Concurrent refreshes can no longer stack multiple authorization dialogs, and denying keeps its 6-hour quiet period for reads that were already waiting.
- A transient server-side 401 now recovers on its own: the same token is retried after the cooldown, and re-logging into Claude Code is picked up automatically with a single Keychain read.

**Interface — Fixed:**

- Hover-expanding the notch no longer flickers ("the island vanished for an instant, then popped open" — with every mascot). The session list's AppKit scroll container blanked the entire panel window for 1-2 frames on macOS 26 when inserted mid-animation; it is now a native SwiftUI scroll view (the scroll indicator is hidden, matching the previous thin-overlay look).
- The pixel-mascot → Bough brand handoff now crossfades smoothly around the trajectory midpoint instead of swapping sprite and size in a single frame, and the sound/settings/quit buttons no longer jump sideways as the expansion settles.
- Expanded content fades in on a fast curve while the panel grows (it previously stayed invisible for the first part of the spring), the divider line joins the same transition, and Reduce Motion now switches the transition to a plain fade.
- The Bough brand mascot is no longer clipped flat at the top on notch screens.

### 简体中文

修复反复出现的钥匙串授权弹窗与刘海展开闪烁。

**用量 — 修复：**

- macOS 钥匙串"Claude Code-credentials"授权弹窗不再每次用量刷新都出现。Bough 现在缓存 token 直至过期，重新读取前先检查钥匙串条目的修改时间（该操作不会触发弹窗）——条目未变化就绝不重复读取。点一次"允许"后，即使不选"始终允许"，正常使用也不再弹窗。
- 并发刷新不再叠加多个授权弹窗；点"拒绝"后的 6 小时静默期对已在等待的读取同样生效。
- 服务器偶发 401 现在可自愈：冷却后自动用原 token 重试；在 Claude Code 重新登录后，仅需一次钥匙串读取即可自动换用新凭据。

**界面 — 修复：**

- 悬停展开刘海不再闪烁（"先消失一瞬间、然后弹出"，任何吉祥物下都会出现）。根因是会话列表的 AppKit 滚动容器在动画中途插入时，会让整个面板窗口在 macOS 26 上空白 1-2 帧；现改为原生 SwiftUI 滚动视图（滚动条隐藏，观感与原细条风格一致）。
- 像素吉祥物与 Bough 品牌图的交接改为轨迹中点附近的平滑渐变（原为单帧内同时换图和跳尺寸的硬切）；声音/设置/退出按钮在展开收尾时不再横向跳动。
- 展开内容随面板增长以快速曲线淡入（此前在弹簧前段完全不可见），顶部分隔线加入同一过渡；"减少动态效果"开启时过渡降级为纯淡入淡出。
- 刘海屏上 Bough 品牌吉祥物不再被削平顶。


## [v1.1.0] - 2026-07-01

### English

OAuth usage channels: direct API reads for Claude Code and Codex, statusLine retirement, and pace forecasting.

**Changed:**

- Usage now reads Claude Code and Codex rate limits directly from the official OAuth usage APIs. Data stays accurate and timely even when the CLIs / desktop apps are not running, and the Today baseline locks within minutes of midnight.
- The Claude Code statusLine wrapper is retired: on first launch after upgrade Bough silently restores your previous statusLine configuration. `~/.bough/claude-usage.json` is now written by Bough itself for the background monitor.
- Today re-locks the daily allowance when a weekly reset (on-time or early) is detected — no more phantom overdraft right after a reset. Usage details gained pace rows (ahead/behind linear pace, projected run-out).

**Notes:**

- First Claude usage fetch may show a one-time macOS Keychain prompt for "Claude Code-credentials" — choose "Always Allow". Denying falls back to an explanatory unavailable state; everything else keeps working.
- With the background monitor enabled, Bough mirrors the Claude access token (never the refresh token) to `~/.bough/claude-oauth-credentials.json` (0600) so sampling continues while the app is closed; the file is deleted when the monitor is disabled or uninstalled.

**Usage — Fixed:**

- Claude Code usage no longer fails with "Claude Code parse-failure": reset timestamps the OAuth usage API returns with fractional seconds are now parsed correctly, so 5-hour and weekly windows populate again (the background monitor, which shares the parser, recovers too).

Music strip: synced lyrics, a seekable progress bar, and online metadata backfill.

**Music — Added:**

- The music strip now shows synced, line-by-line lyrics and a seekable progress bar.
- Online lyrics and artwork are backfilled (QQ Music + NetEase search) for all supported players — Apple Music, Spotify, QQ Music, and NetEase Cloud Music.

**Music — Fixed:**

- Player-identity race during rapid app switching; cross-source metadata mixing in the script fallback; QQ artwork negative-cache now retries after a TTL instead of relying on mtime alone; the OSAScript backoff is now a single state machine; stale poll results are no longer published (generation token); localized player display names now match correctly.

**Interface — Fixed:**

- The no-session notch indicator now morphs to the Bough brand icon and gives haptic feedback when it expands, matching the active bar (it previously showed a coding-agent mascot and skipped the haptic). Internally, the three notch compact bars were unified into one, with no other visual or animation changes.

### 简体中文

OAuth 用量通道：直接读取 Claude Code 和 Codex 的 API、退役 statusLine wrapper 及节奏预测。

**变更：**

- 用量现在直接通过官方 OAuth 用量 API 读取 Claude Code 和 Codex 的配额限制。即使 CLI / 桌面应用未运行，数据也能保持准确及时；当日基准在午夜后数分钟内锁定。
- Claude Code statusLine wrapper 已退役：升级后首次启动时，Bough 会静默恢复你此前的 statusLine 配置。`~/.bough/claude-usage.json` 现在由 Bough 自身写入，供后台监控使用。
- 检测到每周配额重置（准时或提前）时，当日配额会重新锁定，彻底消除重置后的幻影透支。用量详情新增节奏行（超前/落后线性进度、预计耗尽时间）。

**说明：**

- 首次获取 Claude 用量时，可能会出现一次性的 macOS Keychain 提示，请求访问"Claude Code-credentials"——请选择"始终允许"。拒绝后会回退到说明性的不可用状态，其他功能不受影响。
- 启用后台监控后，Bough 会将 Claude access token（不包括 refresh token）镜像到 `~/.bough/claude-oauth-credentials.json`（权限 0600），以便应用关闭时仍能持续采样；禁用监控或卸载应用时，该文件会被删除。

**用量 — 修复：**

- Claude Code 用量不再出现"解析失败"：OAuth 用量 API 返回的带小数秒的重置时间戳现在能正确解析，5 小时与每周窗口重新正常显示（共用同一解析器的后台监控也随之恢复）。

音乐条：同步歌词、可拖动进度条与在线元数据补全。

**音乐 — 新增：**

- 音乐条现在显示逐行同步歌词和可拖动的播放进度条。
- 为所有支持的播放器（Apple Music、Spotify、QQ 音乐、网易云音乐）在线补全歌词与封面（QQ 音乐 + 网易云搜索）。

**音乐 — 修复：**

- 快速切换播放器时的身份竞态；脚本兜底的跨源元数据混淆；QQ 封面负缓存改为 TTL 重试而非仅依赖 mtime；OSAScript 退避合并为单一状态机；过期轮询结果不再发布（generation token）；本地化播放器显示名现在能正确匹配。

**界面 — 修复：**

- 无会话时的刘海指示器现在会在展开时变为 Bough 品牌图标并触发触控板震动，与活跃状态栏一致（此前显示的是编程助手 mascot 且没有震动）。内部将三套刘海紧凑栏合并为一套，无其它视觉或动画变化。

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
