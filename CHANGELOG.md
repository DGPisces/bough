# Changelog

All notable changes to Bough are documented here.

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
