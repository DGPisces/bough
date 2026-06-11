# Releasing Bough

Maintainer runbook for shipping a release. Contributors do not need any of
this — releases are cut by the maintainer only (the `v*` tag ruleset restricts
tag creation to the repository owner).

## 1. Prepare the release PR

```sh
Tools/Release/bump-version.sh X.Y.Z
```

The script rewrites every version-bearing location in one pass (Info.plist
keys, `AppVersion.fallback`, the hardcoded test assertions, and a new
`CHANGELOG.md` entry skeleton), then runs the version-consistency gate.

Then:

1. Replace the `TODO` lines in `CHANGELOG.md` with real release notes.
   Both the `### English` and `### 简体中文` sections are mandatory —
   `Tools/Release/extract-changelog.sh` rejects entries missing either one,
   which would fail the release workflow.
2. Run `swift test --parallel`.
3. Open a PR titled `Prepare vX.Y.Z release` and merge it once CI is green.

## 2. Tag

On the merge commit on `main`:

```sh
git switch main && git pull
git tag vX.Y.Z
git push origin vX.Y.Z
```

Pushing the tag triggers `.github/workflows/release.yml`.

## 3. Approve the release environment

The release job runs in the `release` environment, which requires manual
approval: GitHub → Actions → the queued `release` run → Review deployments →
Approve. (CLI alternative: `gh api -X POST
repos/DGPisces/bough/actions/runs/<run-id>/pending_deployments` with the
environment id and `state=approved`.)

## 4. What the workflow does

Signs and notarizes a universal DMG, publishes the GitHub Release, verifies
the uploaded asset hash, pushes the Sparkle appcast to the `appcast` branch
(deploy key), and force-pushes a `bough-vX.Y.Z` cask branch to
`DGPisces/homebrew-tap` (deploy key). The tap repository's `auto-pr` workflow
then opens a manual-review PR.

## 5. After the workflow

1. Review and merge the tap PR in `DGPisces/homebrew-tap`.
2. Verify:

```sh
gh release view vX.Y.Z --repo DGPisces/bough
curl -fsSL https://raw.githubusercontent.com/DGPisces/bough/appcast/appcast.xml | head
brew update && brew info --cask bough
```

## Troubleshooting

- **Tag pushed but nothing runs:** the tag must match `vX.Y.Z` (or a
  `vX.Y.Z-pre` prerelease, which skips appcast and tap publishing).
- **Tap PR missing:** check the `Open Homebrew tap PR` step logs; the cask
  branch can be re-pushed locally with
  `Tools/Release/release-flow.sh open-tap-pr --tag vX.Y.Z --version X.Y.Z
  --download-url <url> --asset-sha256 <sha>`.
- **Version mismatch failures:** rerun `Tools/Release/check-version-consistency.sh`
  locally; it prints exactly which location disagrees.

## Maintainer notes

- `ci / test-macos26` is an advisory check that runs the test suite on the
  release-builder runner generation. Once it has a stable track record, add it
  to the `main protection` ruleset's required status checks.
