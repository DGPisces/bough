# Contributing to Bough

Thanks for helping improve Bough.

## Local Setup

```sh
git clone https://github.com/DGPisces/bough.git
cd bough
swift package resolve
swift build -c release
swift test
```

## Issues and Pull Requests

For bug reports, include:

- macOS version
- Bough version
- steps to reproduce
- expected result
- actual result

For pull requests:

- branch from `main`
- keep the change focused
- include tests or a clear verification note
- avoid unrelated formatting or metadata churn

All pull requests require maintainer approval before merge. The repository uses
squash merge for a linear `main` history.

## CI Checks

Every pull request must pass the required checks:

- `ci / build-and-test` — `swift build`, `swift test --parallel`, and the
  version-consistency gate on macOS 14.
- `ci / unsigned-packaging-smoke` — unsigned DMG packaging plus a packaged
  usage-monitor smoke test on macOS 26.

`ci / test-macos26` runs the test suite on the newer toolchain for visibility;
it is not required yet. `main` also requires branches to be up to date before
merge, so a rebase (or the maintainer pressing "Update branch") may be needed
before landing.

Run `swift test` locally before pushing. The suite is self-contained: it never
touches your real `~/.bough`, `~/.claude`, or `~/.codex` configuration.

## Changelog and Releases

`CHANGELOG.md` is maintained by the maintainer in release-preparation PRs —
feature PRs should not edit it. The release process is documented in
[docs/RELEASING.md](docs/RELEASING.md).

## Security Reports

Report vulnerabilities through GitHub private vulnerability reporting for
`DGPisces/bough`. Do not post exploit details in public issues or pull requests.

## License

By contributing, you agree that your contribution is licensed under the MIT
License used by this project.
