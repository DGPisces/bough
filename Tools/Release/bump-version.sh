#!/usr/bin/env bash
set -euo pipefail
# Bumps the Bough release version across every tracked location:
#   1-3. Platform/Apple/Info.plist  BoughReleaseLabel / CFBundleShortVersionString / CFBundleVersion
#   4.   Sources/Bough/Settings.swift                    AppVersion.fallback
#   5.   Tests/BoughTests/VersionConsistencyTests.swift  BoughReleaseLabel assertion
#   6.   Tests/BoughTests/SparkleUpdaterConfigTests.swift  version + build + label assertions
#   7.   CHANGELOG.md                                    new bilingual entry skeleton
#
# Usage: Tools/Release/bump-version.sh <X.Y.Z> [--build N]
# CFBundleVersion defaults to the current value + 1.
# See docs/RELEASING.md for the full release runbook.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST="$REPO_ROOT/Platform/Apple/Info.plist"
SETTINGS="$REPO_ROOT/Sources/Bough/Settings.swift"
VERSION_TESTS="$REPO_ROOT/Tests/BoughTests/VersionConsistencyTests.swift"
SPARKLE_TESTS="$REPO_ROOT/Tests/BoughTests/SparkleUpdaterConfigTests.swift"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"

die() { echo "ERROR: $*" >&2; exit 1; }

NEW_VERSION="${1:-}"
[[ -n "$NEW_VERSION" ]] || die "usage: $0 <X.Y.Z> [--build N]"
shift
NEW_BUILD=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) NEW_BUILD="${2:?--build requires a number}"; shift 2 ;;
        *) die "unknown argument '$1' (usage: $0 <X.Y.Z> [--build N])" ;;
    esac
done

[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "version '$NEW_VERSION' must be three numeric components (X.Y.Z)"

for f in "$PLIST" "$SETTINGS" "$VERSION_TESTS" "$SPARKLE_TESTS" "$CHANGELOG"; do
    [[ -f "$f" ]] || die "expected file not found: $f"
done

OLD_VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
OLD_BUILD="$(plutil -extract CFBundleVersion raw "$PLIST")"
[[ "$NEW_VERSION" != "$OLD_VERSION" ]] || die "new version $NEW_VERSION equals current version"
if [[ -z "$NEW_BUILD" ]]; then
    [[ "$OLD_BUILD" =~ ^[0-9]+$ ]] || die "current CFBundleVersion '$OLD_BUILD' is not numeric; pass --build N"
    NEW_BUILD=$((OLD_BUILD + 1))
fi
[[ "$NEW_BUILD" =~ ^[0-9]+$ ]] || die "build '$NEW_BUILD' must be numeric"

! grep -q "^## \[v$NEW_VERSION\]" "$CHANGELOG" \
    || die "CHANGELOG.md already has an entry for v$NEW_VERSION"

# Replaces an exact string exactly once, failing loudly when the source pattern
# has drifted — a silent miss here is precisely the bug this script exists to kill.
replace_exact() {
    local file="$1" old="$2" new="$3"
    local count
    count="$(grep -cF "$old" "$file" || true)"
    [[ "$count" == "1" ]] || die "expected exactly 1 occurrence of '$old' in $file, found $count"
    OLD="$old" NEW="$new" perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/' "$file"
}

plutil -replace BoughReleaseLabel -string "$NEW_VERSION" "$PLIST"
plutil -replace CFBundleShortVersionString -string "$NEW_VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$NEW_BUILD" "$PLIST"

replace_exact "$SETTINGS" \
    "static let fallback = \"$OLD_VERSION\"" \
    "static let fallback = \"$NEW_VERSION\""
replace_exact "$VERSION_TESTS" \
    "plistExtract(\"BoughReleaseLabel\"), \"$OLD_VERSION\")" \
    "plistExtract(\"BoughReleaseLabel\"), \"$NEW_VERSION\")"
replace_exact "$SPARKLE_TESTS" \
    "plistExtract(\"CFBundleShortVersionString\"), \"$OLD_VERSION\")" \
    "plistExtract(\"CFBundleShortVersionString\"), \"$NEW_VERSION\")"
replace_exact "$SPARKLE_TESTS" \
    "plistExtract(\"CFBundleVersion\"), \"$OLD_BUILD\")" \
    "plistExtract(\"CFBundleVersion\"), \"$NEW_BUILD\")"
replace_exact "$SPARKLE_TESTS" \
    "plistExtract(\"BoughReleaseLabel\"), \"$OLD_VERSION\")" \
    "plistExtract(\"BoughReleaseLabel\"), \"$NEW_VERSION\")"

TODAY="$(date +%Y-%m-%d)"
ENTRY_FILE="$(mktemp)"
trap 'rm -f "$ENTRY_FILE"' EXIT
cat > "$ENTRY_FILE" <<EOF
## [v$NEW_VERSION] - $TODAY

### English

- TODO: fill in the English release notes before merging the release PR.

### 简体中文

- TODO: 合并发布 PR 前补全中文发布说明。

EOF
awk -v entry_file="$ENTRY_FILE" '
    /^## \[/ && !inserted {
        while ((getline line < entry_file) > 0) print line
        inserted = 1
    }
    { print }
' "$CHANGELOG" > "$CHANGELOG.tmp"
mv "$CHANGELOG.tmp" "$CHANGELOG"
grep -q "^## \[v$NEW_VERSION\]" "$CHANGELOG" || die "failed to insert CHANGELOG entry"

"$REPO_ROOT/Tools/Release/check-version-consistency.sh"

cat <<EOF
Bumped $OLD_VERSION (build $OLD_BUILD) -> $NEW_VERSION (build $NEW_BUILD).
Next steps:
  1. Replace the TODO lines in CHANGELOG.md with real bilingual release notes.
  2. Open a "Prepare v$NEW_VERSION release" PR and merge it once CI is green.
  3. Tag the merge commit on main: git tag v$NEW_VERSION && git push origin v$NEW_VERSION
  4. Approve the "release" environment run in GitHub Actions (see docs/RELEASING.md).
EOF
