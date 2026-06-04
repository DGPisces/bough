#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

usage() {
    cat >&2 <<'EOF'
Usage: Tools/Release/release-flow.sh <command> [options]

Commands:
  bump           Write release version/build metadata into Platform/Apple/Info.plist.
  prepare        Validate intended version/build/tag metadata.
  build          Build the release DMG, or show the build command with --dry-run.
  publish-asset  Upload a DMG to a GitHub Release and print the download URL.
  update-appcast Update the stable public appcast through Tools/Release/update-appcast.sh.
  verify         Run release alignment and artifact verification gates.
  verify-remote  Wait until the remote public Sparkle feed and artifact are visible.
  assert-new-build
                 Fail if --build is not newer than the current stable appcast.

Common options:
  --tag vX.Y.Z[-rc.N]
  --label X.Y.Z | vX.Y.Z-rc.N
  --dmg PATH
  --asset PATH
  --download-url URL
  --asset-sha256 HASH
  --asset-bytes N
  --feed-url URL
  --appcast PATH
  --version X.Y.Z
  --build N
  --attempts N
  --sleep SECONDS
  --repo OWNER/REPO
  --replace
  --dry-run
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_value() {
    local name="$1"
    local value="$2"
    [[ -n "$value" ]] || die "$name is required"
}

is_prerelease_tag() {
    [[ "${1#v}" == *-* ]]
}

validate_tag() {
    [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9.-]*)?$ ]] \
        || die "--tag must be vX.Y.Z or vX.Y.Z-prerelease (got '$1')"
}

validate_stable_appcast_tag() {
    ! is_prerelease_tag "$1" \
        || die "stable appcast updates only support stable tags; prerelease tags are manual-download only"
}

validate_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "--version must be X.Y.Z (got '$1')"
}

default_label_for_tag() {
    local tag="$1"
    if is_prerelease_tag "$tag"; then
        printf '%s' "$tag"
    else
        printf '%s' "${tag#v}"
    fi
}

validate_label_for_tag() {
    local tag="$1"
    local label="$2"
    if is_prerelease_tag "$tag"; then
        [[ "$label" == "$tag" ]] \
            || die "--label must match prerelease tag '$tag'"
    else
        [[ "$label" == "${tag#v}" ]] \
            || die "--label must match stable tag label '${tag#v}'"
    fi
}

validate_download_url() {
    local url="$1"
    [[ "$url" =~ ^https://github\.com/DGPisces/bough/releases/download/(v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9.-]*)?)/[^/?#]+$ ]] \
        || die "--download-url must be a public GitHub Release download URL: https://github.com/DGPisces/bough/releases/download/vX.Y.Z[-rc.N]/<asset>"
}

validate_download_url_tag() {
    local url="$1"
    local tag="$2"
    validate_download_url "$url"
    if [[ "$url" =~ ^https://github\.com/DGPisces/bough/releases/download/([^/]+)/ ]]; then
        [[ "${BASH_REMATCH[1]}" == "$tag" ]] \
            || die "--download-url tag (${BASH_REMATCH[1]}) must match --tag ($tag)"
    fi
}

validate_public_repo() {
    [[ "$REPO" == "DGPisces/bough" ]] \
        || die "--repo must be DGPisces/bough for the public release flow"
}

print_command() {
    printf '%q' "$1"
    shift || true
    if [[ $# -gt 0 ]]; then
        printf ' %q' "$@"
    fi
    printf '\n'
}

print_env_assignment() {
    printf '%s=%q' "$1" "$2"
}

default_feed_url() {
    printf 'https://raw.githubusercontent.com/DGPisces/bough/appcast/appcast.xml'
}

parse_top_appcast_item() {
    /usr/bin/perl -0ne '
      if (m{<item>(.*?)</item>}s) {
        my $item = $1;
        my ($title) = $item =~ m{<title>([^<]+)</title>}s;
        my ($build) = $item =~ m{<sparkle:version>([^<]+)</sparkle:version>}s;
        my ($short) = $item =~ m{<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>}s;
        my ($enclosure) = defined $item ? $item =~ m{<enclosure\b([^>]*)>}s : undef;
        my ($url) = defined $enclosure ? $enclosure =~ m{\burl="([^"]+)"}s : undef;
        my ($bytes) = defined $enclosure ? $enclosure =~ m{\blength="([^"]+)"}s : undef;
        if (defined $title && defined $build && defined $short && defined $url && defined $bytes) {
          print "title=$title\nbuild=$build\nshort=$short\nurl=$url\nbytes=$bytes\n";
          exit 0;
        }
      }
      exit 1;
    ' "$1"
}

remote_asset_url_allowed() {
    [[ "$1" =~ ^https://github\.com/DGPisces/bough/releases/download/v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9.-]*)?/[^/?#]+$ ]]
}

remote_feed_url_allowed() {
    local url="$1"
    if [[ "$url" == "$(default_feed_url)" ]]; then
        return 0
    fi
    if [[ "$url" =~ ^https://raw\.githubusercontent\.com/DGPisces/bough/[A-Za-z0-9._/-]+\.xml$ ]]; then
        return 0
    fi
    if [[ "$url" =~ ^https://github\.com/DGPisces/bough/releases/download/v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9.-]*)?/[^/?#]+\.xml$ ]]; then
        return 0
    fi
    return 1
}

stable_appcast_url() {
    local appcast_path="${BOUGH_APPCAST_PATH:-$REPO_ROOT/Tools/Release/appcast.xml}"
    /usr/bin/perl -0ne 'if (m{<item>.*?<enclosure\s+[^>]*url="([^"]+)"}s) { print $1; exit }' "$appcast_path"
}

release_plist_path() {
    printf '%s/Platform/Apple/Info.plist' "$REPO_ROOT"
}

plist_value() {
    plutil -extract "$1" raw "$(release_plist_path)"
}

top_appcast_build_from_file() {
    /usr/bin/perl -0ne '
      if (m{<item>.*?<sparkle:version>([^<]+)</sparkle:version>}s) {
        print $1;
        exit 0;
      }
      exit 1;
    ' "$1"
}

current_stable_appcast_build() {
    local appcast_path="${APPCAST_PATH:-}"
    local tmp build
    if [[ -n "$appcast_path" ]]; then
        [[ -f "$appcast_path" ]] || die "appcast file not found: $appcast_path"
        build="$(top_appcast_build_from_file "$appcast_path" || true)"
    else
        tmp="$(mktemp)"
        if ! curl -fsSL --max-time 30 "${FEED_URL:-$(default_feed_url)}" -o "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
        build="$(top_appcast_build_from_file "$tmp" || true)"
        rm -f "$tmp"
    fi
    [[ -z "$build" || "$build" =~ ^[0-9]+$ ]] || die "stable appcast build must be numeric, got: $build"
    printf '%s' "$build"
}

verify_stable_appcast_download_url() {
    local expected="$1"
    local actual
    actual="$(stable_appcast_url)"
    [[ "$actual" == "$expected" ]] \
        || die "stable appcast enclosure URL mismatch: expected $expected got ${actual:-<missing>}"
}

parse_args() {
    TAG=""
    LABEL=""
    DMG=""
    ASSET=""
    DOWNLOAD_URL=""
    ASSET_SHA256=""
    ASSET_BYTES=""
    FEED_URL=""
    APPCAST_PATH="${BOUGH_APPCAST_PATH:-}"
    VERSION=""
    BUILD=""
    REPO="DGPisces/bough"
    DRY_RUN="0"
    REPLACE="0"
    ATTEMPTS="${BOUGH_REMOTE_VERIFY_ATTEMPTS:-12}"
    SLEEP_SECONDS="${BOUGH_REMOTE_VERIFY_SLEEP:-30}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --channel) die "--channel is no longer supported; use the public release flow" ;;
            --asset-api-url) die "--asset-api-url is no longer supported; use --download-url" ;;
            --ledger|--decision) die "$1 is not part of the public release flow" ;;
            --tag) TAG="${2:?--tag requires a value}"; shift 2 ;;
            --label) LABEL="${2:?--label requires a value}"; shift 2 ;;
            --dmg) DMG="${2:?--dmg requires a path}"; shift 2 ;;
            --asset) ASSET="${2:?--asset requires a path}"; shift 2 ;;
            --download-url) DOWNLOAD_URL="${2:?--download-url requires a URL}"; shift 2 ;;
            --asset-sha256) ASSET_SHA256="${2:?--asset-sha256 requires a hash}"; shift 2 ;;
            --asset-bytes) ASSET_BYTES="${2:?--asset-bytes requires a byte count}"; shift 2 ;;
            --feed-url) FEED_URL="${2:?--feed-url requires a URL}"; shift 2 ;;
            --appcast) APPCAST_PATH="${2:?--appcast requires a path}"; shift 2 ;;
            --version) VERSION="${2:?--version requires a value}"; shift 2 ;;
            --build) BUILD="${2:?--build requires a value}"; shift 2 ;;
            --repo) REPO="${2:?--repo requires OWNER/REPO}"; shift 2 ;;
            --attempts) ATTEMPTS="${2:?--attempts requires a value}"; shift 2 ;;
            --sleep) SLEEP_SECONDS="${2:?--sleep requires a value}"; shift 2 ;;
            --replace) REPLACE="1"; shift ;;
            --dry-run) DRY_RUN="1"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown argument '$1'" ;;
        esac
    done
}

cmd_bump() {
    parse_args "$@"
    require_value "--tag" "$TAG"
    validate_tag "$TAG"
    local tag_label="${TAG#v}"
    local tag_base="${tag_label%%-*}"
    VERSION="${VERSION:-$tag_base}"
    validate_version "$VERSION"
    [[ "$tag_base" == "$VERSION" ]] \
        || die "--tag base version ($tag_base) must match --version ($VERSION)"
    LABEL="${LABEL:-$(default_label_for_tag "$TAG")}"
    validate_label_for_tag "$TAG" "$LABEL"

    local source_build latest_build appcast_build
    source_build="$(plist_value CFBundleVersion)"
    [[ "$source_build" =~ ^[0-9]+$ ]] || die "source CFBundleVersion must be numeric, got: $source_build"
    if [[ -z "$BUILD" ]]; then
        appcast_build="$(current_stable_appcast_build)" \
            || die "could not read current stable appcast build; pass --build explicitly or retry with network access"
        latest_build="$source_build"
        if [[ -n "$appcast_build" && "$appcast_build" -gt "$latest_build" ]]; then
            latest_build="$appcast_build"
        fi
        BUILD="$((latest_build + 1))"
    fi
    [[ "$BUILD" =~ ^[0-9]+$ ]] || die "--build must be numeric"

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "release metadata bump:"
        echo "  version=$VERSION"
        echo "  build=$BUILD"
        echo "  tag=$TAG"
        echo "  label=$LABEL"
        print_command plutil -replace CFBundleShortVersionString -string "$VERSION" Platform/Apple/Info.plist
        print_command plutil -replace CFBundleVersion -string "$BUILD" Platform/Apple/Info.plist
        print_command plutil -replace BoughReleaseLabel -string "$LABEL" Platform/Apple/Info.plist
        return
    fi

    local plist
    plist="$(release_plist_path)"
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
    plutil -replace CFBundleVersion -string "$BUILD" "$plist"
    plutil -replace BoughReleaseLabel -string "$LABEL" "$plist"
    echo "Release metadata updated:"
    echo "  version=$VERSION"
    echo "  build=$BUILD"
    echo "  tag=$TAG"
    echo "  label=$LABEL"
}

cmd_prepare() {
    parse_args "$@"
    require_value "--version" "$VERSION"
    require_value "--build" "$BUILD"
    validate_version "$VERSION"
    [[ "$BUILD" =~ ^[0-9]+$ ]] || die "--build must be numeric"
    TAG="${TAG:-v${VERSION}}"
    validate_tag "$TAG"
    local tag_label="${TAG#v}"
    local tag_base="${tag_label%%-*}"
    [[ "$tag_base" == "$VERSION" ]] \
        || die "--tag base version ($tag_base) must match --version ($VERSION)"
    LABEL="${LABEL:-$(default_label_for_tag "$TAG")}"
    validate_label_for_tag "$TAG" "$LABEL"

    echo "Release prepare OK:"
    echo "  version=$VERSION"
    echo "  build=$BUILD"
    echo "  tag=$TAG"
    echo "  label=$LABEL"
    echo
    printf 'export BOUGH_RELEASE_TAG=%q\n' "$TAG"
    printf 'export BOUGH_RELEASE_LABEL=%q\n' "$LABEL"
}

cmd_assert_new_build() {
    parse_args "$@"
    require_value "--build" "$BUILD"
    [[ "$BUILD" =~ ^[0-9]+$ ]] || die "--build must be numeric"

    local appcast_build
    appcast_build="$(current_stable_appcast_build)" \
        || die "could not read current stable appcast build"
    if [[ -z "$appcast_build" ]]; then
        echo "No stable appcast build found; accepting build $BUILD."
        return
    fi
    if [[ "$BUILD" -le "$appcast_build" ]]; then
        die "release build $BUILD must be greater than current stable appcast build $appcast_build. Run: Tools/Release/release-flow.sh bump --tag <next-tag>"
    fi
    echo "Release build OK: $BUILD > current stable appcast build $appcast_build"
}

cmd_build() {
    parse_args "$@"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "BUILD_ARCH=arm64 Tools/Build/build-dmg.sh"
        return
    fi
    BUILD_ARCH="${BUILD_ARCH:-arm64}" "$REPO_ROOT/Tools/Build/build-dmg.sh"
}

cmd_publish_asset() {
    parse_args "$@"
    validate_public_repo
    require_value "--tag" "$TAG"
    require_value "--asset" "$ASSET"
    validate_tag "$TAG"
    [[ -f "$ASSET" || "$DRY_RUN" == "1" ]] || die "asset not found: $ASSET"

    local asset_name
    asset_name="$(basename "$ASSET")"
    local upload_args=(gh release upload "$TAG" "$ASSET" --repo "$REPO")
    [[ "$REPLACE" == "0" ]] || upload_args+=(--clobber)
    if [[ "$DRY_RUN" == "1" ]]; then
        print_command "${upload_args[@]}"
        print_command gh release view "$TAG" --repo "$REPO" --json assets --jq ".assets[] | select(.name == \"$asset_name\") | .browserDownloadUrl"
        return
    fi

    gh release view "$TAG" --repo "$REPO" >/dev/null \
        || die "GitHub Release $TAG does not exist; create it before publish-asset"
    "${upload_args[@]}"
    gh release view "$TAG" --repo "$REPO" --json assets \
        --jq ".assets[] | select(.name == \"$asset_name\") | .browserDownloadUrl"
}

cmd_update_appcast() {
    parse_args "$@"
    require_value "--tag" "$TAG"
    require_value "--dmg" "$DMG"
    require_value "--download-url" "$DOWNLOAD_URL"
    validate_tag "$TAG"
    validate_stable_appcast_tag "$TAG"
    validate_download_url_tag "$DOWNLOAD_URL" "$TAG"
    LABEL="${LABEL:-${TAG#v}}"
    validate_label_for_tag "$TAG" "$LABEL"

    if [[ "$DRY_RUN" == "1" ]]; then
        print_env_assignment BOUGH_RELEASE_TAG "$TAG"
        printf ' '
        print_env_assignment BOUGH_RELEASE_LABEL "$LABEL"
        printf ' '
        print_env_assignment BOUGH_DMG_DOWNLOAD_URL "$DOWNLOAD_URL"
        printf ' '
        print_command Tools/Release/update-appcast.sh "$DMG"
        return
    fi

    [[ -f "$DMG" ]] || die "DMG not found: $DMG"
    BOUGH_RELEASE_TAG="$TAG" \
    BOUGH_RELEASE_LABEL="$LABEL" \
    BOUGH_DMG_DOWNLOAD_URL="$DOWNLOAD_URL" \
        "$REPO_ROOT/Tools/Release/update-appcast.sh" "$DMG"
}

cmd_verify() {
    parse_args "$@"
    require_value "--tag" "$TAG"
    require_value "--dmg" "$DMG"
    require_value "--download-url" "$DOWNLOAD_URL"
    validate_tag "$TAG"
    validate_download_url_tag "$DOWNLOAD_URL" "$TAG"

    if [[ "$DRY_RUN" == "1" ]]; then
        print_env_assignment BOUGH_RELEASE_TAG "$TAG"
        printf ' '
        print_command Tools/Release/check-version-consistency.sh --with-dmg "$DMG"
        if ! is_prerelease_tag "$TAG"; then
            print_command xmllint --noout Tools/Release/appcast.xml
            print_command Tools/Release/release-flow.sh _assert-stable-appcast-url --download-url "$DOWNLOAD_URL"
        fi
        print_command hdiutil verify "$DMG"
        print_command xcrun stapler validate "$DMG"
        print_command spctl --assess --type open --context context:primary-signature -v "$DMG"
        return
    fi

    [[ -f "$DMG" ]] || die "DMG not found: $DMG"
    BOUGH_RELEASE_TAG="$TAG" "$REPO_ROOT/Tools/Release/check-version-consistency.sh" --with-dmg "$DMG"
    if ! is_prerelease_tag "$TAG"; then
        xmllint --noout "$REPO_ROOT/Tools/Release/appcast.xml"
        verify_stable_appcast_download_url "$DOWNLOAD_URL"
    fi
    hdiutil verify "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
}

cmd_verify_remote() {
    parse_args "$@"
    require_value "--tag" "$TAG"
    require_value "--version" "$VERSION"
    require_value "--build" "$BUILD"
    validate_tag "$TAG"
    validate_version "$VERSION"
    [[ "$BUILD" =~ ^[0-9]+$ ]] || die "--build must be numeric"
    [[ "$ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || die "--attempts must be a positive integer"
    [[ "$SLEEP_SECONDS" =~ ^[0-9]+$ ]] || die "--sleep must be numeric"
    [[ -z "$ASSET_BYTES" || "$ASSET_BYTES" =~ ^[0-9]+$ ]] || die "--asset-bytes must be numeric"
    [[ -z "$ASSET_SHA256" || "$ASSET_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]] || die "--asset-sha256 must be a 64-character hex SHA-256"

    LABEL="${LABEL:-$(default_label_for_tag "$TAG")}"
    validate_label_for_tag "$TAG" "$LABEL"
    FEED_URL="${FEED_URL:-$(default_feed_url)}"
    remote_feed_url_allowed "$FEED_URL" \
        || die "remote feed URL is not allowed: $FEED_URL"
    if is_prerelease_tag "$TAG" && [[ "$FEED_URL" == "$(default_feed_url)" ]]; then
        die "prerelease verify-remote requires --feed-url; default appcast is stable-only"
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "wait for remote update feed:"
        echo "  feed=$FEED_URL"
        echo "  title=Version $LABEL"
        echo "  shortVersionString=$VERSION"
        echo "  build=$BUILD"
        [[ -z "$ASSET_SHA256" ]] || echo "  assetSha256=$ASSET_SHA256"
        [[ -z "$ASSET_BYTES" ]] || echo "  assetBytes=$ASSET_BYTES"
        echo "  attempts=$ATTEMPTS"
        echo "  sleep=$SLEEP_SECONDS"
        return
    fi

    local expected_title="Version $LABEL"
    local tmp_feed tmp_asset tmp_parse
    tmp_feed="$(mktemp)"
    tmp_asset="$(mktemp)"
    tmp_parse="$(mktemp)"
    trap 'rm -f "$tmp_feed" "$tmp_asset" "$tmp_parse"' RETURN

    local attempt last_error
    last_error="remote feed did not expose $expected_title build $BUILD"
    for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
        if curl -fsSL --max-time 30 "$FEED_URL" -o "$tmp_feed" \
            && parse_top_appcast_item "$tmp_feed" > "$tmp_parse"; then
            local remote_title remote_build remote_short remote_url remote_bytes
            remote_title="$(awk -F= '$1=="title"{print substr($0, index($0, "=") + 1)}' "$tmp_parse")"
            remote_build="$(awk -F= '$1=="build"{print substr($0, index($0, "=") + 1)}' "$tmp_parse")"
            remote_short="$(awk -F= '$1=="short"{print substr($0, index($0, "=") + 1)}' "$tmp_parse")"
            remote_url="$(awk -F= '$1=="url"{print substr($0, index($0, "=") + 1)}' "$tmp_parse")"
            remote_bytes="$(awk -F= '$1=="bytes"{print substr($0, index($0, "=") + 1)}' "$tmp_parse")"
            if [[ "$remote_title" == "$expected_title" && "$remote_short" == "$VERSION" && "$remote_build" == "$BUILD" ]]; then
                if ! remote_asset_url_allowed "$remote_url"; then
                    die "remote appcast enclosure URL is not allowed: $remote_url"
                fi
                if [[ -n "$ASSET_BYTES" && "$remote_bytes" != "$ASSET_BYTES" ]]; then
                    last_error="remote appcast length mismatch: expected $ASSET_BYTES got ${remote_bytes:-<missing>}"
                    echo "Remote asset metadata not current yet (attempt $attempt/$ATTEMPTS): $last_error" >&2
                elif [[ -n "$ASSET_SHA256" ]]; then
                    if curl -fsSL --max-time 120 "$remote_url" -o "$tmp_asset"; then
                        local actual_sha
                        actual_sha="$(shasum -a 256 "$tmp_asset" | awk '{print $1}')"
                        if [[ "$actual_sha" == "$ASSET_SHA256" ]]; then
                            echo "Remote update feed OK:"
                            echo "  feed=$FEED_URL"
                            echo "  title=$remote_title"
                            echo "  shortVersionString=$remote_short"
                            echo "  build=$remote_build"
                            echo "  url=$remote_url"
                            echo "  assetSha256=$ASSET_SHA256"
                            return
                        fi
                        last_error="remote asset SHA-256 mismatch: expected $ASSET_SHA256 got $actual_sha"
                        echo "Remote asset not current yet (attempt $attempt/$ATTEMPTS): $last_error" >&2
                    else
                        last_error="remote asset unavailable: $remote_url"
                        echo "Remote asset unavailable yet (attempt $attempt/$ATTEMPTS): $remote_url" >&2
                    fi
                else
                    echo "Remote update feed OK:"
                    echo "  feed=$FEED_URL"
                    echo "  title=$remote_title"
                    echo "  shortVersionString=$remote_short"
                    echo "  build=$remote_build"
                    echo "  url=$remote_url"
                    return
                fi
            else
                last_error="remote feed not current: title=${remote_title:-<missing>} short=${remote_short:-<missing>} build=${remote_build:-<missing>}"
                echo "Remote feed not current yet (attempt $attempt/$ATTEMPTS): title=${remote_title:-<missing>} short=${remote_short:-<missing>} build=${remote_build:-<missing>}" >&2
            fi
        else
            last_error="remote feed unavailable: $FEED_URL"
            echo "Remote feed unavailable yet (attempt $attempt/$ATTEMPTS): $FEED_URL" >&2
        fi
        if [[ "$attempt" -lt "$ATTEMPTS" ]]; then
            sleep "$SLEEP_SECONDS"
        fi
    done

    die "remote update feed did not expose $expected_title build $BUILD after $ATTEMPTS attempts: $last_error"
}

cmd_assert_stable_appcast_url() {
    parse_args "$@"
    require_value "--download-url" "$DOWNLOAD_URL"
    validate_download_url "$DOWNLOAD_URL"
    verify_stable_appcast_download_url "$DOWNLOAD_URL"
}

COMMAND="${1:-}"
if [[ -z "$COMMAND" ]]; then
    usage
    exit 2
fi
shift

case "$COMMAND" in
    bump) cmd_bump "$@" ;;
    prepare) cmd_prepare "$@" ;;
    assert-new-build) cmd_assert_new_build "$@" ;;
    build) cmd_build "$@" ;;
    publish-asset) cmd_publish_asset "$@" ;;
    update-appcast) cmd_update_appcast "$@" ;;
    verify) cmd_verify "$@" ;;
    verify-remote) cmd_verify_remote "$@" ;;
    _assert-stable-appcast-url) cmd_assert_stable_appcast_url "$@" ;;
    -h|--help) usage ;;
    *) die "unknown command '$COMMAND'" ;;
esac
