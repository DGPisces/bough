<p align="center">
  <img src="Assets/Brand/logo.png" alt="Bough" width="240"/>
</p>

# Bough

<p align="center">
  <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/DGPisces/bough/actions/workflows/ci.yml"><img src="https://github.com/DGPisces/bough/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-black.svg" alt="Platform: macOS 14+">
</p>

Bough is a macOS menu bar utility that keeps AI coding agent status, usage, music, and AirDrop visible at the top of your screen.

![Bough notch panel demo](Assets/README/panel-session-music-airdrop.png)

## Features

- Shows session state for Codex, Claude Code, Cursor, and other supported tools right in the Mac notch / menu bar.
- Permission requests, questions, completion, busy, idle — every state at a glance. Click to jump back to the matching terminal or editor window.
- Tracks usage for Codex and Claude Code by reading each tool's official usage API directly — accurate even when the tools aren't running. Alerts you when approaching limits and when cooldowns end. (First Claude usage read shows a one-time macOS Keychain authorization — choose Always Allow.)
- Now playing music and lyrics, right in the menu bar — no need to switch windows.
- AirDrop drag panel for faster file reception.
- Works whether you're developing locally, SSH'd into a remote server, or using any common terminal and editor.

<details>
<summary>Supported tools</summary>

| Tool | Bough mascot |
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

## Install

### Homebrew Cask

```sh
brew tap DGPisces/tap
brew install --cask bough
```

### GitHub Releases DMG

1. Open [GitHub Releases](https://github.com/DGPisces/bough/releases).
2. Download the latest versioned Bough DMG asset, for example `Bough-vX.Y.Z.dmg`.
3. Open the DMG and drag `Bough.app` into `/Applications`.
4. On first launch, follow the macOS prompts to confirm and grant the required permissions.

## Automatic Updates

- Homebrew Cask installs — let Homebrew handle it:

  ```sh
  brew update
  brew upgrade --cask bough
  ```

- DMG installs — Bough has a built-in updater. Stable builds check the public stable channel for signed updates.

## Build From Source

Requires macOS 14+, Swift 5.9+, and Xcode Command Line Tools.

```sh
swift package resolve
swift build -c release
swift test
```

The release binary is at `.build/release/Bough`.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Report security issues through GitHub private vulnerability reporting.

## Credits

Bough is a fork of [CodeIsland](https://github.com/wxtsky/CodeIsland) — thanks to the original project for laying the foundation. See [`CREDITS.md`](CREDITS.md) for license and third-party notices.

## License

Bough is released under the MIT License. See [`LICENSE`](LICENSE).
