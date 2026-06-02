#!/usr/bin/env bash
set -euo pipefail
# Verifies version-string agreement across the source-tree Info.plist,
# Tools/Release/appcast.xml, and the git tag on HEAD (when present). With
# `--with-dmg PATH` additionally compares the DMG-embedded plist.
#
# Modes:
#   - Source-only (default): assert plist + main appcast agree. Tagged release
#     commits must also agree with the git tag.
#   - Full (--with-dmg PATH): also assert DMG-embedded plist agrees.
#
# Empty-appcast handling: when Tools/Release/appcast.xml contains no <item>
# blocks, the appcast comparison is skipped. This supports the first public RC,
# which is manual-download only until a stable release updates the appcast.
#
# Untagged-HEAD handling: most development commits are untagged; the git-tag comparison
# is skipped (with an INFO line on stderr) when HEAD has no tag. Appcast still
# has to match the checked-in source version so the main appcast follows the
# release branch.
#
# Prerelease label handling: set BOUGH_RELEASE_TAG=v1.0.0-rc.1 only to validate
# manual-download prerelease metadata before a real git tag exists. Appcast
# update tooling rejects prerelease tags; this gate only maps the prerelease tag
# to its numeric bundle base version (1.0.0). Stable tags still compare exactly.
#
# Next-release build handling: set BOUGH_SKIP_APPCAST_VERSION_CHECK=1 while
# building the DMG for the next version before Tools/Release/update-appcast.sh has
# generated the matching feed entry. Source-vs-DMG and git-tag checks still run;
# rerun this script without the flag after updating Tools/Release/appcast.xml.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST="$REPO_ROOT/Platform/Apple/Info.plist"
APPCAST="$REPO_ROOT/Tools/Release/appcast.xml"

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
DMG_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-dmg)
            DMG_PATH="${2:?--with-dmg requires a path}"
            shift 2
            ;;
        *)
            echo "ERROR: unknown argument '$1' (usage: $0 [--with-dmg PATH])" >&2
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# 1. Source-of-truth: source-tree plist.
# ---------------------------------------------------------------------------
if [[ ! -f "$PLIST" ]]; then
    echo "ERROR: Info.plist not found at $PLIST" >&2
    exit 2
fi
SRC_SHORT=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
SRC_BUILD=$(plutil -extract CFBundleVersion raw "$PLIST")

# ---------------------------------------------------------------------------
# 2. Latest appcast entry (top <item>). Empty if no items present.
# ---------------------------------------------------------------------------
APPCAST_SHORT=""
APPCAST_BUILD=""
if [[ -f "$APPCAST" ]]; then
    APPCAST_SHORT=$(/usr/bin/perl -ne 'if (/<sparkle:shortVersionString>([^<]+)</) { print $1; exit; }' "$APPCAST")
    APPCAST_BUILD=$(/usr/bin/perl -ne 'if (/<sparkle:version>([^<]+)</) { print $1; exit; }' "$APPCAST")
fi

# ---------------------------------------------------------------------------
# 3. git tag on HEAD (empty = untagged development commit).
# ---------------------------------------------------------------------------
GIT_TAG=$(git -C "$REPO_ROOT" tag --points-at HEAD 2>/dev/null | head -n1 || true)
ENV_RELEASE_TAG="${BOUGH_RELEASE_TAG:-}"
RELEASE_TAG_SOURCE="git tag on HEAD"
RELEASE_TAG="$GIT_TAG"
if [[ -n "$ENV_RELEASE_TAG" ]]; then
    RELEASE_TAG_SOURCE="BOUGH_RELEASE_TAG"
    RELEASE_TAG="$ENV_RELEASE_TAG"
fi
RELEASE_TAG_VER="${RELEASE_TAG#v}"  # strip leading 'v'

numeric_version_base() {
    local tag_ver="$1"
    if [[ "$tag_ver" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-[A-Za-z0-9][A-Za-z0-9.-]*)?$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# 4. DMG checks (optional, only when invoked with --with-dmg).
# ---------------------------------------------------------------------------
DMG_SHORT=""
DMG_BUILD=""
if [[ -n "$DMG_PATH" ]]; then
    if [[ ! -f "$DMG_PATH" ]]; then
        echo "ERROR: DMG not found at $DMG_PATH" >&2
        exit 2
    fi
    MOUNTPOINT=$(mktemp -d)
    trap 'hdiutil detach -quiet "$MOUNTPOINT" 2>/dev/null || true; rm -rf "$MOUNTPOINT"' EXIT
    hdiutil attach -nobrowse -quiet -mountpoint "$MOUNTPOINT" "$DMG_PATH"
    DMG_PLIST="$MOUNTPOINT/Bough.app/Contents/Info.plist"
    if [[ ! -f "$DMG_PLIST" ]]; then
        echo "ERROR: Info.plist not found inside DMG at $DMG_PLIST" >&2
        exit 2
    fi
    DMG_SHORT=$(plutil -extract CFBundleShortVersionString raw "$DMG_PLIST")
    DMG_BUILD=$(plutil -extract CFBundleVersion raw "$DMG_PLIST")
fi

# ---------------------------------------------------------------------------
# 5. Compare. Fail loudly on any disagreement; accumulate first, exit once.
# ---------------------------------------------------------------------------
fail=0
SKIP_APPCAST_VERSION_CHECK="${BOUGH_SKIP_APPCAST_VERSION_CHECK:-0}"

if ! [[ "$SRC_SHORT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "MISMATCH: Info.plist CFBundleShortVersionString=$SRC_SHORT is not a three-component numeric Apple bundle version" >&2
    fail=1
fi

if [[ "$SKIP_APPCAST_VERSION_CHECK" == "1" ]]; then
    echo "INFO: BOUGH_SKIP_APPCAST_VERSION_CHECK=1 — skipping appcast agreement check." >&2
elif [[ -n "$APPCAST_SHORT" && "$SRC_SHORT" != "$APPCAST_SHORT" ]]; then
    echo "MISMATCH: Info.plist CFBundleShortVersionString=$SRC_SHORT but appcast sparkle:shortVersionString=$APPCAST_SHORT" >&2
    fail=1
fi
if [[ "$SKIP_APPCAST_VERSION_CHECK" != "1" && -n "$APPCAST_BUILD" && "$SRC_BUILD" != "$APPCAST_BUILD" ]]; then
    echo "MISMATCH: Info.plist CFBundleVersion=$SRC_BUILD but appcast sparkle:version=$APPCAST_BUILD" >&2
    fail=1
fi
if [[ "$SKIP_APPCAST_VERSION_CHECK" == "1" ]]; then
    :
elif [[ -z "$APPCAST_SHORT" && -z "$APPCAST_BUILD" ]]; then
    echo "INFO: Tools/Release/appcast.xml has no <item> entries — skipping appcast agreement check." >&2
elif [[ -z "$APPCAST_SHORT" ]]; then
    echo "MISMATCH: Tools/Release/appcast.xml has <sparkle:version> but no <sparkle:shortVersionString> (build='$APPCAST_BUILD')" >&2
    fail=1
elif [[ -z "$APPCAST_BUILD" ]]; then
    echo "MISMATCH: Tools/Release/appcast.xml has <sparkle:shortVersionString> but no <sparkle:version> (short='$APPCAST_SHORT')" >&2
    fail=1
fi

if [[ -n "$RELEASE_TAG_VER" ]]; then
    if ! RELEASE_TAG_BASE=$(numeric_version_base "$RELEASE_TAG_VER"); then
        echo "MISMATCH: $RELEASE_TAG_SOURCE=$RELEASE_TAG is not vX.Y.Z or vX.Y.Z-prerelease" >&2
        fail=1
    elif [[ "$SRC_SHORT" != "$RELEASE_TAG_BASE" ]]; then
        echo "MISMATCH: Info.plist CFBundleShortVersionString=$SRC_SHORT but $RELEASE_TAG_SOURCE=$RELEASE_TAG maps to $RELEASE_TAG_BASE" >&2
        fail=1
    else
        echo "INFO: $RELEASE_TAG_SOURCE=$RELEASE_TAG maps to bundle short version $RELEASE_TAG_BASE." >&2
    fi
elif [[ -z "$RELEASE_TAG_VER" ]]; then
    echo "INFO: HEAD has no tag and BOUGH_RELEASE_TAG is unset — skipping release-tag agreement check (untagged development commit)." >&2
fi

if [[ -n "$GIT_TAG" && -n "$ENV_RELEASE_TAG" && "$GIT_TAG" != "$ENV_RELEASE_TAG" ]]; then
    echo "MISMATCH: BOUGH_RELEASE_TAG=$ENV_RELEASE_TAG but git tag on HEAD=$GIT_TAG" >&2
    fail=1
fi

if [[ -n "$DMG_SHORT" && "$SRC_SHORT" != "$DMG_SHORT" ]]; then
    echo "MISMATCH: source plist short=$SRC_SHORT but DMG-embedded plist short=$DMG_SHORT" >&2
    fail=1
fi
if [[ -n "$DMG_BUILD" && "$SRC_BUILD" != "$DMG_BUILD" ]]; then
    echo "MISMATCH: source plist build=$SRC_BUILD but DMG-embedded plist build=$DMG_BUILD" >&2
    fail=1
fi

if [[ $fail -ne 0 ]]; then
    echo "Version consistency check FAILED." >&2
    exit 1
fi
echo "Version consistency OK: short=$SRC_SHORT build=$SRC_BUILD"
exit 0
