#!/usr/bin/env bash
set -euo pipefail

# Usage: ./Tools/Release/update-appcast.sh <dmg-path>
# Example:
#   BOUGH_RELEASE_TAG=v1.0.0 \
#   BOUGH_DMG_DOWNLOAD_URL=https://github.com/DGPisces/bough/releases/download/v1.0.0/Bough.dmg \
#   ./Tools/Release/update-appcast.sh .build/Bough.dmg
#
# Produces / updates Tools/Release/appcast.xml for the stable public Sparkle
# feed. Prerelease tags are manual-download only and must not update this feed.

DMG_PATH="${1:-}"
if [[ -z "$DMG_PATH" ]]; then
    echo "Usage: $0 <dmg-path>" >&2
    exit 1
fi
if [[ ! -f "$DMG_PATH" ]]; then
    echo "ERROR: DMG not found at $DMG_PATH" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build"
APPCAST="$REPO_ROOT/Tools/Release/appcast.xml"
SIGN_UPDATE="$BUILD_DIR/artifacts/sparkle/Sparkle/bin/sign_update"

if [[ ! -x "$SIGN_UPDATE" ]]; then
    echo "ERROR: sign_update not at $SIGN_UPDATE — run 'swift build -c release' first." >&2
    exit 1
fi

MOUNTPOINT=$(mktemp -d)
trap 'hdiutil detach -quiet "$MOUNTPOINT" 2>/dev/null || true; rm -rf "$MOUNTPOINT"' EXIT
hdiutil attach -nobrowse -quiet -mountpoint "$MOUNTPOINT" "$DMG_PATH"
DMG_PLIST="$MOUNTPOINT/Bough.app/Contents/Info.plist"
if [[ ! -f "$DMG_PLIST" ]]; then
    echo "ERROR: DMG-embedded Info.plist missing at $DMG_PLIST" >&2
    exit 1
fi
VERSION=$(plutil -extract CFBundleShortVersionString raw "$DMG_PLIST")
BUILD=$(plutil -extract CFBundleVersion raw "$DMG_PLIST")
RELEASE_TAG="${BOUGH_RELEASE_TAG:-v${VERSION}}"
RELEASE_LABEL="${BOUGH_RELEASE_LABEL:-${RELEASE_TAG#v}}"

if [[ -n "${BOUGH_RELEASE_CHANNEL:-}" ]]; then
    echo "ERROR: BOUGH_RELEASE_CHANNEL is no longer supported; use the public release flow." >&2
    exit 2
fi
if [[ "${RELEASE_TAG#v}" == *-* ]]; then
    echo "ERROR: stable appcast updates only support stable tags; prerelease tags are manual-download only." >&2
    exit 2
fi
if [[ "$RELEASE_LABEL" != "${RELEASE_TAG#v}" ]]; then
    echo "ERROR: BOUGH_RELEASE_LABEL must match stable tag label '${RELEASE_TAG#v}'." >&2
    exit 2
fi

FEED_URL="${BOUGH_APPCAST_FEED_URL:-https://raw.githubusercontent.com/DGPisces/bough/appcast/appcast.xml}"
ITEM_LINK_URL="${BOUGH_APPCAST_ITEM_LINK_URL:-https://github.com/DGPisces/bough/releases/tag/${RELEASE_TAG}}"
PUB_DATE="$(LC_TIME=en_US.UTF-8 date -u "+%a, %d %b %Y %H:%M:%S +0000")"
LENGTH="$(stat -f%z "$DMG_PATH")"
MIN_OS="14.0"

if [[ -z "${BOUGH_DMG_DOWNLOAD_URL:-}" ]]; then
    echo "ERROR: appcast updates require BOUGH_DMG_DOWNLOAD_URL." >&2
    echo "       Expected public download URL: https://github.com/DGPisces/bough/releases/download/${RELEASE_TAG}/<asset>" >&2
    exit 2
fi
if [[ ! "$BOUGH_DMG_DOWNLOAD_URL" =~ ^https://github\.com/DGPisces/bough/releases/download/(v[0-9]+\.[0-9]+\.[0-9]+)/[^/?#]+$ ]]; then
    echo "ERROR: BOUGH_DMG_DOWNLOAD_URL must be a public GitHub Release download URL, got: $BOUGH_DMG_DOWNLOAD_URL" >&2
    exit 2
fi
if [[ "${BASH_REMATCH[1]}" != "$RELEASE_TAG" ]]; then
    echo "ERROR: BOUGH_DMG_DOWNLOAD_URL tag (${BASH_REMATCH[1]}) must match BOUGH_RELEASE_TAG ($RELEASE_TAG)." >&2
    exit 2
fi
DOWNLOAD_URL="$BOUGH_DMG_DOWNLOAD_URL"

if [[ -n "${SPARKLE_EDDSA_PRIVATE_KEY:-}" ]]; then
    echo "==> Signing $DMG_PATH with Sparkle EdDSA key from environment"
    SIGN_OUTPUT="$(printf '%s' "$SPARKLE_EDDSA_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$DMG_PATH")"
else
    echo "==> Signing $DMG_PATH with Sparkle EdDSA key from Keychain"
    SIGN_OUTPUT="$("$SIGN_UPDATE" "$DMG_PATH")"
fi
ED_SIG="$(printf '%s' "$SIGN_OUTPUT" | /usr/bin/perl -ne 'print $1 if /sparkle:edSignature="([^"]+)"/')"
if [[ -z "$ED_SIG" ]]; then
    echo "ERROR: could not parse EdDSA signature from sign_update output:" >&2
    echo "$SIGN_OUTPUT" >&2
    exit 1
fi

NEW_ITEM="    <item>
      <title>Version ${RELEASE_LABEL}</title>
      <link>${ITEM_LINK_URL}</link>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure
        url=\"${DOWNLOAD_URL}\"
        sparkle:edSignature=\"${ED_SIG}\"
        length=\"${LENGTH}\"
        type=\"application/octet-stream\" />
    </item>"

if [[ ! -f "$APPCAST" ]]; then
    echo "==> Creating new $APPCAST"
    /bin/mkdir -p "$(dirname "$APPCAST")"
    cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/"
     version="2.0">
  <channel>
    <title>Bough</title>
    <link>${FEED_URL}</link>
    <description>Stable Bough updates</description>
    <language>en</language>
  </channel>
</rss>
EOF
fi

echo "==> Updating version ${VERSION} in $APPCAST"
if /usr/bin/grep -qF "<sparkle:version>${BUILD}</sparkle:version>" "$APPCAST"; then
    if [[ "${BOUGH_APPCAST_REPLACE_EXISTING:-0}" != "1" ]]; then
        echo "ERROR: build ${BUILD} (v${VERSION}) is already in Tools/Release/appcast.xml. Bump CFBundleVersion in Platform/Apple/Info.plist, edit by hand, or set BOUGH_APPCAST_REPLACE_EXISTING=1 for a same-build asset re-sign." >&2
        exit 1
    fi
    NEW_ITEM="$NEW_ITEM" BUILD="$BUILD" /usr/bin/perl -0pi -e '
        BEGIN {
            $item = $ENV{"NEW_ITEM"};
            $build = $ENV{"BUILD"};
        }
        s{\n    <item>\n(?:(?!\n    </item>).)*?<sparkle:version>\Q$build\E</sparkle:version>(?:(?!\n    </item>).)*?\n    </item>}{\n$item}s
            or die "ERROR: could not replace appcast item for build $build\n";
    ' "$APPCAST"
    echo "==> Replaced existing build ${BUILD} entry"
else
    /usr/bin/perl -i -pe '
        BEGIN { $done = 0; $item = shift @ARGV; }
        if (!$done && (/<item>/ || /<\/channel>/)) {
            print $item . "\n";
            $done = 1;
        }
    ' "$NEW_ITEM" "$APPCAST"
fi

echo "==> Tools/Release/appcast.xml updated:"
echo "    releaseTag=${RELEASE_TAG}"
echo "    releaseLabel=${RELEASE_LABEL}"
echo "    shortVersionString=${VERSION}"
echo "    version (CFBundleVersion)=${BUILD}"
echo "    length=${LENGTH}"
echo "    pubDate=${PUB_DATE}"
echo "    url=${DOWNLOAD_URL}"
