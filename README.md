<p align="center">
  <img src="Assets/Brand/logo.png" alt="Bough" width="240"/>
</p>

# Bough

<p align="center">
  <a href="README.zh-CN.md">简体中文</a>
</p>

Bough is a macOS notch utility that keeps AI coding agents, usage, music, lyrics, and AirDrop state visible at the top of your screen.

![Bough notch panel demo](Assets/README/panel-session-music-airdrop.png)

## Features

- Shows session state for Codex, Claude Code, Cursor, and other supported tools in the notch area.
- Surfaces permission requests, questions, completion, busy, and idle states, with jump-back support to the matching terminal or app.
- Tracks AI usage windows with optional usage and recovery notifications.
- Displays music playback, lyrics, and AirDrop drag surfaces.
- Supports local, remote SSH, and common terminal/editor workflows.
- Includes the Bough mascot, tool mascots, pixel sounds, diagnostics, and Settings previews.

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

The current stable release is `v1.0.0`.

1. Open [GitHub Releases](https://github.com/DGPisces/bough/releases).
2. Download the latest `Bough.dmg`.
3. Open the DMG and drag `Bough.app` into `/Applications`.
4. On first launch, follow macOS prompts for opening the app and granting required permissions.

## Automatic Updates

Bough uses the public repository stable channel for automatic updates. Stable builds check the public update feed for signed in-app updates.

## Build From Source

Requires macOS 14+, Swift 5.9+, and Xcode Command Line Tools.

```sh
swift package resolve
swift build -c release
swift test
```

The release executable is `.build/release/Bough`.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Report security issues through GitHub private vulnerability reporting.

## Thanks

Thanks to [CodeIsland](https://github.com/wxtsky/CodeIsland) for providing the foundation. See [`CREDITS.md`](CREDITS.md) for license and third-party notices.

## License

Bough is released under the MIT License. See [`LICENSE`](LICENSE).
