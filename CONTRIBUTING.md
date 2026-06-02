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

## Security Reports

Report vulnerabilities through GitHub private vulnerability reporting for
`DGPisces/bough`. Do not post exploit details in public issues or pull requests.

## License

By contributing, you agree that your contribution is licensed under the MIT
License used by this project.
