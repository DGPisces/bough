<p align="center">
  <img src="Assets/Brand/logo.png" alt="Bough" width="240"/>
</p>

# Bough

<p align="center">
  <a href="README.md">English</a>
</p>

Bough 是一款 macOS 刘海实用工具，把 AI 编码智能体、用量、音乐、歌词和 AirDrop 等状态放到屏幕顶部的可视空间里。

![Bough 刘海面板演示](Assets/README/panel-session-music-airdrop.png)

## 功能

- 在刘海区域显示 Codex、Claude Code、Cursor 等工具的会话状态。
- 展示权限请求、问题、完成、忙碌和空闲等状态，并支持回到对应终端或应用。
- 跟踪 AI 用量窗口，提供可选的用量提醒和恢复提示。
- 显示音乐播放信息、歌词和 AirDrop 拖拽面板。
- 支持本机、远程 SSH 和常见终端/编辑器工作流。
- 内置 Bough mascot、工具 mascot、像素音效、诊断和设置页预览。

<details>
<summary>支持的工具</summary>

| 工具 | Bough mascot |
|---|---|
| Codex | <img src="Assets/README/mascots/codex.gif" alt="Codex mascot" width="56"/> |
| Claude Code | <img src="Assets/README/mascots/claude.gif" alt="Claude Code mascot" width="56"/> |
| Cursor | <img src="Assets/README/mascots/cursor.gif" alt="Cursor mascot" width="56"/> |
| GitHub Copilot | <img src="Assets/README/mascots/copilot.gif" alt="GitHub Copilot mascot" width="56"/> |
| Gemini CLI | <img src="Assets/README/mascots/gemini.gif" alt="Gemini CLI mascot" width="56"/> |
| OpenCode | <img src="Assets/README/mascots/opencode.gif" alt="OpenCode mascot" width="56"/> |
| Qwen Code | <img src="Assets/README/mascots/qwen.gif" alt="Qwen Code mascot" width="56"/> |
| Kimi | <img src="Assets/README/mascots/kimi.gif" alt="Kimi mascot" width="56"/> |
| Trae | <img src="Assets/README/mascots/trae.gif" alt="Trae mascot" width="56"/> |
| Qoder | <img src="Assets/README/mascots/qoder.gif" alt="Qoder mascot" width="56"/> |
| Antigravity | <img src="Assets/README/mascots/antigravity.gif" alt="Antigravity mascot" width="56"/> |
| CodeBuddy | <img src="Assets/README/mascots/codebuddy.gif" alt="CodeBuddy mascot" width="56"/> |
| WorkBuddy | <img src="Assets/README/mascots/workbuddy.gif" alt="WorkBuddy mascot" width="56"/> |
| Droid | <img src="Assets/README/mascots/droid.gif" alt="Droid mascot" width="56"/> |
| Hermes | <img src="Assets/README/mascots/hermes.gif" alt="Hermes mascot" width="56"/> |
| StepFun | <img src="Assets/README/mascots/stepfun.gif" alt="StepFun mascot" width="56"/> |

</details>

## 安装

当前稳定版是 `v1.0.3`。

### Homebrew Cask

```sh
brew tap DGPisces/tap
brew install --cask bough
```

等价的一行命令：

```sh
brew install --cask DGPisces/tap/bough
```

### GitHub Releases DMG

1. 打开 [GitHub Releases](https://github.com/DGPisces/bough/releases)。
2. 下载最新 `Bough.dmg`。
3. 打开 DMG，将 `Bough.app` 拖入 `/Applications`。
4. 首次启动时，按 macOS 提示完成打开确认和必要权限设置。

## 自动更新

- Homebrew Cask 安装版由 Homebrew 管理更新：

  ```sh
  brew update
  brew upgrade --cask bough
  ```

- GitHub Releases DMG 安装版使用 Bough 的应用内更新。稳定版会通过公开 stable channel 检查签名更新。

## 从源码构建

需要 macOS 14+、Swift 5.9+ 和 Xcode Command Line Tools。

```sh
swift package resolve
swift build -c release
swift test
```

Release 构建产物位于 `.build/release/Bough`。

## 贡献

贡献流程见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。安全问题请通过 GitHub private vulnerability reporting 提交。

## 致谢

感谢 [CodeIsland](https://github.com/wxtsky/CodeIsland) 提供基础。许可与第三方说明见 [`CREDITS.md`](CREDITS.md)。

## 许可

Bough 使用 MIT License。详见 [`LICENSE`](LICENSE)。
