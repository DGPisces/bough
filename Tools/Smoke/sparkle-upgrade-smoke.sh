#!/usr/bin/env bash
# Tools/Smoke/sparkle-upgrade-smoke.sh
#
# D-03 Smoke test — Phase 18: Sparkle Live-Update Wiring
#
# Proves that a Sparkle-driven in-place upgrade:
#   (a) advances the bundle from CFBundleVersion=1 to CFBundleVersion=2, and
#   (b) leaves the user's ~/.bough/usage-daily.json baseline untouched.
#
# Flow (10 steps from RESEARCH.md):
#   1.  Build v1 .app bundle  (CFBundleVersion=1 in a temp Info.plist copy)
#   2.  Build v2 .app bundle  (CFBundleVersion=2)
#   3.  Package v2 into a minimal DMG via hdiutil
#   4.  Sign v2 DMG with Sparkle's sign_update
#   5.  Generate appcast.xml pointing at file://$STAGING/ via generate_appcast
#   6.  Override SUFeedURL in v1 bundle to file://$STAGING/appcast.xml
#   7.  Seed ~/.bough/usage-daily.json with a known JSON baseline
#   8.  Launch v1 bundle and wait for Sparkle to detect + install the update
#   9.  Assert: resulting bundle's CFBundleVersion == 2
#   10. Assert: ~/.bough/usage-daily.json matches the seeded baseline
#
# Headless / CI mode:
#   Set SKIP_INTERACTIVE=1 to skip steps 7–10 (the interactive Sparkle UI).
#   Steps 1–6 (build, sign, generate appcast) run unconditionally and exercise
#   the full signing + appcast-generation pipeline.  Useful for CI.
#
# Usage:
#   BOUGH_SMOKE_TOUCH_REAL_USAGE=1 bash Tools/Smoke/sparkle-upgrade-smoke.sh
#                                                        # full interactive run
#   SKIP_INTERACTIVE=1 bash Tools/Smoke/sparkle-upgrade-smoke.sh  # CI / headless
#
# Prerequisites:
#   - swift build -c release (populates .build/artifacts/sparkle/Sparkle/bin/)
#   - Sparkle private EdDSA key present in login Keychain
#     (service: https://sparkle-project.org, account: ed25519)
#   - hdiutil, plutil, open available (standard macOS utilities)
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLS="$REPO_ROOT/.build/artifacts/sparkle/Sparkle/bin"
STAGING_ROOT="$(mktemp -d)"
STAGING="$STAGING_ROOT/smoke"
BOUGH_DATA_DIR="$HOME/.bough"
USAGE_FILE="$BOUGH_DATA_DIR/usage-daily.json"
ORIGINAL_USAGE_BACKUP=""
ORIGINAL_USAGE_EXISTED="0"
USAGE_SEEDED="0"
SKIP_INTERACTIVE="${SKIP_INTERACTIVE:-0}"
TOUCH_REAL_USAGE="${BOUGH_SMOKE_TOUCH_REAL_USAGE:-0}"

# ---------------------------------------------------------------------------
# Cleanup trap — removes STAGING on EXIT (success or failure)
# ---------------------------------------------------------------------------
cleanup() {
    restore_usage_baseline
    rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

mkdir -p "$STAGING"

restore_usage_baseline() {
    [[ "$USAGE_SEEDED" == "1" ]] || return 0
    if [[ "$ORIGINAL_USAGE_EXISTED" == "1" && -n "$ORIGINAL_USAGE_BACKUP" && -f "$ORIGINAL_USAGE_BACKUP" ]]; then
        mkdir -p "$BOUGH_DATA_DIR"
        cp "$ORIGINAL_USAGE_BACKUP" "$USAGE_FILE"
    else
        rm -f "$USAGE_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight() {
    echo "=== Preflight: checking required tools ===" >&2

    if [[ ! -x "$TOOLS/sign_update" ]]; then
        echo "ERROR: sign_update not found at $TOOLS/sign_update" >&2
        echo "Run 'swift build -c release' first to populate Sparkle tools." >&2
        exit 1
    fi
    if [[ ! -x "$TOOLS/generate_appcast" ]]; then
        echo "ERROR: generate_appcast not found at $TOOLS/generate_appcast" >&2
        exit 1
    fi
    echo "==> Tools OK: $TOOLS" >&2
}

# ---------------------------------------------------------------------------
# Step 1 + 2: Build v1 and v2 bundles
#
# Each bundle is assembled from the swift build output with a patched
# Info.plist (CFBundleVersion patched via plutil). Interactive runs build a
# launchable .app by embedding Sparkle.framework and fixing the binary rpath.
#
# RESEARCH.md pitfall #3: bundles must embed the REAL SUPublicEDKey so
# Sparkle's EdDSA verification passes.  We read it from the source plist.
# ---------------------------------------------------------------------------
embed_sparkle_runtime() {
    local contents="$1"
    local binary="$contents/MacOS/Bough"
    local frameworks_dir="$contents/Frameworks"
    local sparkle_src="$REPO_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

    if [[ ! -d "$sparkle_src" ]]; then
        echo "ERROR: $sparkle_src not found. Run 'swift build -c release' first." >&2
        exit 1
    fi

    mkdir -p "$frameworks_dir"
    rm -rf "$frameworks_dir/Sparkle.framework"
    cp -R "$sparkle_src" "$frameworks_dir/"

    if ! otool -l "$binary" | grep -q "@executable_path/../Frameworks"; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$binary"
    fi
}

build_bundle() {
    local version="$1"         # integer CFBundleVersion (1 or 2)
    local bundle_dir="$STAGING/Bough_v${version}.app"

    echo "=== Step: build_bundle v${version} ===" >&2

    local contents="$bundle_dir/Contents"
    local macos_dir="$contents/MacOS"
    mkdir -p "$macos_dir"

    # Copy source plist and patch CFBundleVersion
    local plist_src="$REPO_ROOT/Platform/Apple/Info.plist"
    local plist_dst="$contents/Info.plist"
    cp "$plist_src" "$plist_dst"
    plutil -replace CFBundleVersion -integer "$version" "$plist_dst"

    # For v1: override SUFeedURL to the local file:// appcast (step 6 below)
    # (done in a second call after appcast is generated — see override_feed_url)

    local swift_exe
    swift_exe="$REPO_ROOT/.build/release/Bough"
    if [[ -f "$swift_exe" ]]; then
        cp "$swift_exe" "$macos_dir/Bough"
        embed_sparkle_runtime "$contents"
    else
        if [[ "$SKIP_INTERACTIVE" != "1" ]]; then
            echo "ERROR: interactive smoke requires a real .build/release/Bough executable." >&2
            echo "Run 'swift build -c release' first, or set SKIP_INTERACTIVE=1 for pipeline-only validation." >&2
            exit 1
        fi
        echo "WARNING: .build/release/Bough not found; creating pipeline-only executable stub" >&2
        printf '#!/bin/sh\nexec echo "Bough stub v%s"\n' "$version" > "$macos_dir/Bough"
        chmod +x "$macos_dir/Bough"
    fi

    echo "==> Built $bundle_dir (CFBundleVersion=$version)" >&2
}

# ---------------------------------------------------------------------------
# Step 3: Package v2 bundle into a DMG
# ---------------------------------------------------------------------------
make_dmg() {
    echo "=== Step 3: packaging v2 bundle into DMG ===" >&2

    local bundle="$STAGING/Bough_v2.app"
    local dmg="$STAGING/Bough_v2.dmg"

    hdiutil create \
        -volname "Bough" \
        -srcfolder "$bundle" \
        -ov \
        -format UDZO \
        "$dmg" >/dev/null

    echo "==> DMG created: $dmg" >&2
}

# ---------------------------------------------------------------------------
# Step 4: Sign the v2 DMG with Sparkle's sign_update
# ---------------------------------------------------------------------------
sign_dmg() {
    echo "=== Step 4: signing v2 DMG ===" >&2

    local dmg="$STAGING/Bough_v2.dmg"
    local sign_output
    sign_output="$("$TOOLS/sign_update" "$dmg")"

    # Verify signature was produced
    local ed_sig
    ed_sig="$(printf '%s' "$sign_output" | \
        /usr/bin/perl -ne 'print $1 if /sparkle:edSignature="([^"]+)"/')"

    if [[ -z "$ed_sig" ]]; then
        echo "ERROR: sign_update did not produce an edSignature." >&2
        echo "Output was: $sign_output" >&2
        echo "Ensure the private EdDSA key is in the login Keychain." >&2
        exit 1
    fi

    echo "==> DMG signed (edSignature extracted OK)" >&2
}

# ---------------------------------------------------------------------------
# Step 5: Generate appcast.xml pointing at file://$STAGING/
# ---------------------------------------------------------------------------
generate_appcast_xml() {
    echo "=== Step 5: generating appcast.xml ===" >&2

    # Capture stderr separately so it's available on failure. The previous
    # `2>/dev/null || true` swallowed all error output — if generate_appcast
    # failed (missing Keychain private key, malformed DMG), the only visible
    # error was the vague "did not produce an appcast XML file" message below.
    local gen_stderr
    gen_stderr=$( "$TOOLS/generate_appcast" \
        --download-url-prefix "file://$STAGING/" \
        "$STAGING/" 2>&1 ) || {
        echo "ERROR: generate_appcast failed:" >&2
        echo "$gen_stderr" >&2
        exit 1
    }

    local appcast="$STAGING/appcast.xml"
    if [[ ! -f "$appcast" ]]; then
        # generate_appcast may name it differently; search the staging root.
        for candidate in "$STAGING"/*.xml; do
            if [[ -f "$candidate" ]]; then
                appcast="$candidate"
                break
            fi
        done
    fi
    if [[ -z "$appcast" ]] || [[ ! -f "$appcast" ]]; then
        echo "ERROR: generate_appcast did not produce an appcast XML file in $STAGING" >&2
        if [[ -n "$gen_stderr" ]]; then
            echo "generate_appcast output:" >&2
            echo "$gen_stderr" >&2
        fi
        exit 1
    fi

    # Normalise name to appcast.xml for predictable reference in step 6
    if [[ "$appcast" != "$STAGING/appcast.xml" ]]; then
        mv "$appcast" "$STAGING/appcast.xml"
    fi

    echo "==> Appcast generated: $STAGING/appcast.xml" >&2
}

# ---------------------------------------------------------------------------
# Step 6: Override SUFeedURL in v1 bundle to file://$STAGING/appcast.xml
# ---------------------------------------------------------------------------
override_feed_url() {
    echo "=== Step 6: overriding SUFeedURL in v1 bundle ===" >&2

    local plist="$STAGING/Bough_v1.app/Contents/Info.plist"
    plutil -replace SUFeedURL -string "file://$STAGING/appcast.xml" "$plist"

    echo "==> SUFeedURL set to file://$STAGING/appcast.xml" >&2
}

# ---------------------------------------------------------------------------
# Step 7: Seed ~/.bough/usage-daily.json with a known baseline
# ---------------------------------------------------------------------------
seed_usage() {
    echo "=== Step 7: seeding usage-daily.json baseline ===" >&2
    if [[ "$TOUCH_REAL_USAGE" != "1" ]]; then
        echo "ERROR: interactive Sparkle preservation smoke writes real $USAGE_FILE." >&2
        echo "Set BOUGH_SMOKE_TOUCH_REAL_USAGE=1 to opt in after backing up user data." >&2
        exit 2
    fi

    mkdir -p "$BOUGH_DATA_DIR"
    if [[ "$USAGE_SEEDED" != "1" ]]; then
        if [[ -f "$USAGE_FILE" ]]; then
            ORIGINAL_USAGE_EXISTED="1"
            ORIGINAL_USAGE_BACKUP="$STAGING_ROOT/original-usage-daily.json"
            cp "$USAGE_FILE" "$ORIGINAL_USAGE_BACKUP"
        fi
        USAGE_SEEDED="1"
    fi
    local baseline='{"2026-01-01":{"tokens":100,"sessions":5}}'
    printf '%s' "$baseline" > "$USAGE_FILE"

    echo "==> Seeded smoke baseline: $USAGE_FILE (original restored on exit)" >&2
}

# ---------------------------------------------------------------------------
# Step 8: Launch v1 with Sparkle (interactive — skipped when SKIP_INTERACTIVE=1)
# ---------------------------------------------------------------------------
launch_and_upgrade() {
    echo "=== Step 8: launching v1 bundle (Sparkle upgrade) ===" >&2
    # NOTE: This step requires a GUI session and user interaction to approve
    # the Sparkle update prompt.  It cannot run headlessly in CI.
    open -W "$STAGING/Bough_v1.app" --args --check-for-updates-immediately

    echo "==> Bundle launched and closed." >&2
}

# ---------------------------------------------------------------------------
# Step 9: Assert final bundle version == 2
# ---------------------------------------------------------------------------
assert_version() {
    echo "=== Step 9: asserting final bundle version ===" >&2

    local plist="$STAGING/Bough_v1.app/Contents/Info.plist"
    local final_version
    final_version="$(plutil -extract CFBundleVersion raw "$plist")"

    if [[ "$final_version" != "2" ]]; then
        echo "FAIL: expected CFBundleVersion=2 after upgrade, got '$final_version'" >&2
        exit 1
    fi
    echo "==> CFBundleVersion == 2 OK" >&2
}

# ---------------------------------------------------------------------------
# Step 10: Assert usage-daily.json matches the seeded baseline
# ---------------------------------------------------------------------------
assert_data_survival() {
    echo "=== Step 10: asserting usage-daily.json survived upgrade ===" >&2

    if [[ ! -f "$USAGE_FILE" ]]; then
        echo "FAIL: $USAGE_FILE not found after upgrade" >&2
        exit 1
    fi

    local expected='{"2026-01-01":{"tokens":100,"sessions":5}}'
    local actual
    actual="$(cat "$USAGE_FILE")"

    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: usage-daily.json contents changed after upgrade." >&2
        echo "  expected: $expected" >&2
        echo "  got:      $actual" >&2
        exit 1
    fi
    echo "==> usage-daily.json baseline survived OK" >&2
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "=== Sparkle upgrade smoke test (D-03) ===" >&2
    if [[ "$SKIP_INTERACTIVE" == "1" ]]; then
        echo "==> SKIP_INTERACTIVE=1: steps 7-10 (UI + assertions) will be skipped" >&2
    elif [[ "$TOUCH_REAL_USAGE" != "1" ]]; then
        echo "ERROR: full interactive smoke writes real $USAGE_FILE." >&2
        echo "Set BOUGH_SMOKE_TOUCH_REAL_USAGE=1 to opt in after backing up user data." >&2
        exit 2
    fi

    preflight

    # Steps 1-2: build bundles
    build_bundle 1
    build_bundle 2

    # Step 3: package v2
    make_dmg

    # Step 4: sign v2 DMG
    sign_dmg

    # Step 5: generate appcast
    generate_appcast_xml

    # Step 6: point v1 at local appcast
    override_feed_url

    if [[ "$SKIP_INTERACTIVE" == "1" ]]; then
        echo "==> Signing + appcast-generation pipeline complete (interactive steps skipped)" >&2
        echo "PARTIAL (pipeline-only; interactive Sparkle upgrade not verified)" >&2
        exit 0
    fi

    # Steps 7-10: interactive upgrade + assertions
    seed_usage
    launch_and_upgrade
    assert_version
    assert_data_survival

    echo "=== PASS: Sparkle upgrade smoke test complete ===" >&2
}

main "$@"
