#!/usr/bin/env bash
set -euo pipefail

# Usage: [BUILD_ARCH=universal|arm64] ./Tools/Build/build-dmg.sh
# Example: ./Tools/Build/build-dmg.sh
# Example: BUILD_ARCH=arm64 SKIP_SIGN=1 SKIP_NOTARIZE=1 ./Tools/Build/build-dmg.sh
#
# Version is read from Platform/Apple/Info.plist.
# To ship a new release: edit Platform/Apple/Info.plist (CFBundleShortVersionString +
# CFBundleVersion), commit, then run this script. The release-checklist banner
# at the end echoes the version it built from for the `gh release create` step.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build"
RELEASE_DIR="$BUILD_DIR/release"
STAGING_DIR="$BUILD_DIR/dmg-staging"
APP_DIR="$STAGING_DIR/Bough.app"
CONTENTS_DIR="$APP_DIR/Contents"
OUTPUT_DMG="$BUILD_DIR/Bough.dmg"
BUILD_ARCH="${BUILD_ARCH:-universal}"

# Read the version from the source plist. Never from a CLI arg.
VERSION=$(plutil -extract CFBundleShortVersionString raw "$REPO_ROOT/Platform/Apple/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$REPO_ROOT/Platform/Apple/Info.plist")

case "$BUILD_ARCH" in
    universal|arm64)
        ;;
    *)
        echo "ERROR: BUILD_ARCH must be 'universal' or 'arm64' (got '$BUILD_ARCH')" >&2
        exit 1
        ;;
esac

echo "==> Verifying version consistency"
"$REPO_ROOT/Tools/Release/check-version-consistency.sh"

echo "==> Building Bough ${VERSION} (${BUILD_ARCH})"

cd "$REPO_ROOT"
case "$BUILD_ARCH" in
    universal)
        # Build for both architectures
        swift build -c release --arch arm64
        swift build -c release --arch x86_64
        ;;
    arm64)
        swift build -c release --arch arm64
        ;;
esac

ARM_DIR="$BUILD_DIR/arm64-apple-macosx/release"
X86_DIR="$BUILD_DIR/x86_64-apple-macosx/release"

echo "==> Assembling .app bundle"

# Clean and recreate staging
rm -rf "$STAGING_DIR"
mkdir -p "$CONTENTS_DIR/MacOS"
mkdir -p "$CONTENTS_DIR/Helpers"
mkdir -p "$CONTENTS_DIR/Library/LaunchAgents"
mkdir -p "$CONTENTS_DIR/Resources"

case "$BUILD_ARCH" in
    universal)
        # Create universal binaries
        lipo -create "$ARM_DIR/Bough" "$X86_DIR/Bough" \
             -output "$CONTENTS_DIR/MacOS/Bough"
        lipo -create "$ARM_DIR/bough-bridge" "$X86_DIR/bough-bridge" \
             -output "$CONTENTS_DIR/Helpers/bough-bridge"
        lipo -create "$ARM_DIR/bough-usage-monitor" "$X86_DIR/bough-usage-monitor" \
             -output "$CONTENTS_DIR/Helpers/bough-usage-monitor"
        ;;
    arm64)
        cp "$ARM_DIR/Bough" "$CONTENTS_DIR/MacOS/Bough"
        cp "$ARM_DIR/bough-bridge" "$CONTENTS_DIR/Helpers/bough-bridge"
        cp "$ARM_DIR/bough-usage-monitor" "$CONTENTS_DIR/Helpers/bough-usage-monitor"
        ;;
esac
chmod +x "$CONTENTS_DIR/MacOS/Bough" \
    "$CONTENTS_DIR/Helpers/bough-bridge" \
    "$CONTENTS_DIR/Helpers/bough-usage-monitor"

cp "$REPO_ROOT/Platform/Apple/LaunchAgents/dev.dgpisces.bough.usage-monitor.plist" \
    "$CONTENTS_DIR/Library/LaunchAgents/dev.dgpisces.bough.usage-monitor.plist"
plutil -lint "$CONTENTS_DIR/Library/LaunchAgents/dev.dgpisces.bough.usage-monitor.plist"

# Copy the source Info.plist verbatim into the assembled bundle.
cp "$REPO_ROOT/Platform/Apple/Info.plist" "$CONTENTS_DIR/Info.plist"

# Compile app icon and asset catalog. Use the classical .appiconset format —
# the Xcode 26 .icon (Icon Composer) format was removed in this phase because
# actool composites .icon layers over a tile fill (e.g. "system-light"), which
# leaks a visible white halo at the rounded-rect perimeter.
xcrun actool \
    --output-format human-readable-text \
    --notices --warnings --errors \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist /dev/null \
    --compile "$CONTENTS_DIR/Resources" \
    "$REPO_ROOT/Platform/Apple/Assets.xcassets"

# Override actool's truncated .icns (it strips sizes above the 128@2x range
# under --target-device mac --minimum-deployment-target 14.0) with the 10-size
# iconutil-baked .icns from Sources/Bough/Resources — both files are generated
# from the same canonical icon-master-1024.png so semantics match.
if [ -f "$REPO_ROOT/Sources/Bough/Resources/AppIcon.icns" ]; then
    cp "$REPO_ROOT/Sources/Bough/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
fi

# Copy SPM resource bundles into Contents/Resources/ — putting them at the .app
# root breaks Developer ID signing with "unsealed contents present in the bundle
# root". Bundle.module already checks resourceURL, so this layout loads fine.
for bundle in "$BUILD_DIR"/*/release/*.bundle; do
    if [ -e "$bundle" ]; then
        cp -R "$bundle" "$CONTENTS_DIR/Resources/"
        break
    fi
done

# ---------------------------------------------------------------------------
# Embed Sparkle.framework. The default release build keeps Sparkle universal;
# arm64 builds thin it while copying so the unsigned CI artifact stays ARM-only.
# The xcframework slice already contains signed Autoupdate / Updater.app / XPC
# services, so we keep those signatures intact and sign only the outer bundle
# below — never pass --deep/--force through the framework.
# ---------------------------------------------------------------------------
mkdir -p "$CONTENTS_DIR/Frameworks"
SPARKLE_SRC="$BUILD_DIR/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$SPARKLE_SRC" ]; then
    echo "ERROR: $SPARKLE_SRC not found. Run 'swift build -c release' first to let SwiftPM resolve Sparkle." >&2
    exit 1
fi
rm -rf "$CONTENTS_DIR/Frameworks/Sparkle.framework"
case "$BUILD_ARCH" in
    universal)
        cp -R "$SPARKLE_SRC" "$CONTENTS_DIR/Frameworks/"
        ;;
    arm64)
        ditto --arch arm64 "$SPARKLE_SRC" "$CONTENTS_DIR/Frameworks/Sparkle.framework"
        ;;
esac
echo "==> Embedded Sparkle.framework from $SPARKLE_SRC"

# SwiftPM builds binaries with @loader_path as the only non-system rpath, which
# resolves Sparkle when the .dylib sits next to the executable (as it does
# inside .build/). Inside a real .app the binary lives in Contents/MacOS while
# the framework lives in Contents/Frameworks, so we add @executable_path/..
# /Frameworks explicitly. Changing the load commands invalidates any prior
# signature — we re-sign below.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$CONTENTS_DIR/MacOS/Bough"
echo "==> Added @executable_path/../Frameworks rpath to Bough binary"

echo "==> App bundle assembled at $APP_DIR"

# ---------------------------------------------------------------------------
# Developer ID signing. SKIP_SIGN=1 uses an ad-hoc bundle signature for local
# dev smoke: the app is not distributable, but Info.plist/resources are sealed
# so macOS services such as UNUserNotificationCenter see the real bundle ID.
# Override the identity with SIGN_IDENTITY=... if you have a different cert.
# ---------------------------------------------------------------------------
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
adhoc_sign_app_bundle() {
    echo "==> Applying ad-hoc bundle signature for local smoke"
    codesign --force --deep --sign - "$APP_DIR"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
}

if [[ -z "$SIGN_IDENTITY" && "${SKIP_SIGN:-0}" != "1" ]]; then
    echo "ERROR: SIGN_IDENTITY env required (or set SKIP_SIGN=1)" >&2
    echo "Hint: SIGN_IDENTITY=\"Developer ID Application: <Owner Name> (<Team ID>)\"" >&2
    exit 1
fi
if [ "${SKIP_SIGN:-0}" = "1" ]; then
    echo "==> SKIP_SIGN=1 — no Developer ID signature will be applied"
    adhoc_sign_app_bundle
elif security find-identity -v -p codesigning | grep -q "$(printf '%s' "$SIGN_IDENTITY" | sed 's/[][\\.^$*/]/\\&/g')"; then
    echo "==> Signing with '$SIGN_IDENTITY' (inside-out for Sparkle, then outer bundle)"
    SPARKLE_FW="$CONTENTS_DIR/Frameworks/Sparkle.framework"
    SPARKLE_B="$SPARKLE_FW/Versions/B"

    # Inside-out: seal Sparkle's inner components with our identity first so
    # hardened runtime + notarization accept them. --force replaces the adhoc
    # signature SwiftPM left in place. No --deep at any step — we walk the
    # tree ourselves to keep ordering explicit.
    for xpc in "$SPARKLE_B"/XPCServices/*.xpc; do
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$xpc"
    done
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$SPARKLE_B/Autoupdate"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$SPARKLE_B/Updater.app"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$SPARKLE_FW"

    # Bundled helpers (hook bridge) also need a proper signature before the
    # outer bundle is sealed, otherwise codesign's nested check rejects the
    # parent with "code object is not signed at all / In subcomponent: ...".
    for helper in "$CONTENTS_DIR"/Helpers/*; do
        [ -f "$helper" ] || continue
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$helper"
    done

    # Finally, sign the main bundle. Entitlements only on the top-level app —
    # Sparkle components have their own entitlements baked into their signatures.
    codesign --force --options runtime --timestamp \
        --entitlements "$REPO_ROOT/Platform/Apple/Bough.entitlements" \
        --sign "$SIGN_IDENTITY" \
        "$APP_DIR"

    echo "==> Verifying nested signatures"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
else
    echo "==> Developer ID identity '$SIGN_IDENTITY' not in keychain — using ad-hoc bundle signature"
    echo "    (install your Developer ID cert or set SIGN_IDENTITY=...)"
    adhoc_sign_app_bundle
fi

echo "==> Creating DMG"

# Remove previous DMG if exists
rm -f "$OUTPUT_DMG"

create-dmg \
    --volname "Bough ${VERSION}" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "Bough.app" 175 190 \
    --hide-extension "Bough.app" \
    --app-drop-link 425 190 \
    --no-internet-enable \
    --filesystem APFS \
    "$OUTPUT_DMG" \
    "$STAGING_DIR/"

# Codesign the DMG container itself. Without this `spctl --assess` reports
# "no usable signature" on the dmg even when the inner .app is properly
# signed and the dmg is notarized + stapled — Sparkle's update flow can
# fail with "An error occurred while running the updater" in that state.
# Stapler still works without this step, but Sparkle's helper handoff is
# happier when the container is signed.
if [ "${SKIP_SIGN:-0}" != "1" ] && [[ "$SIGN_IDENTITY" != "-" ]]; then
    echo "==> Code-signing the DMG container"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$OUTPUT_DMG"
fi

# ---------------------------------------------------------------------------
# Notarize + staple. Uses the "Bough" keychain profile by default
# (xcrun notarytool store-credentials Bough ...). Skippable via
# SKIP_NOTARIZE=1 for local dev builds. Override with NOTARY_PROFILE=....
# ---------------------------------------------------------------------------
NOTARY_PROFILE="${NOTARY_PROFILE:-Bough}"
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "==> SKIP_NOTARIZE=1 — release DMG is not notarized"
elif [ "${SKIP_SIGN:-0}" = "1" ]; then
    echo "==> Skipping notarization (app was not Developer-ID signed)"
else
    echo "==> Submitting to Apple notary service (profile '$NOTARY_PROFILE')"
    if xcrun notarytool submit "$OUTPUT_DMG" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait; then
        xcrun stapler staple "$OUTPUT_DMG"
    else
        echo "==> Notarization failed — inspect the log above and, if missing, run:"
        echo "    xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id <team> --password <app-specific>"
        exit 1
    fi
fi

echo "==> Verifying version consistency against built DMG"
"$REPO_ROOT/Tools/Release/check-version-consistency.sh" --with-dmg "$OUTPUT_DMG"

echo "==> Done: $OUTPUT_DMG"

if [ "${SKIP_SIGN:-0}" != "1" ] && [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    echo ""
    echo "==> Release checklist:"
    echo "    1. Tools/Release/release-flow.sh prepare --version ${VERSION} --build ${BUILD} --tag v${VERSION}"
    echo "    2. gh release create v${VERSION} --repo DGPisces/bough --title \"Bough ${VERSION}\" --notes-file <notes.md> --draft"
    echo "    3. Tools/Release/release-flow.sh publish-asset --tag v${VERSION} --asset \"$OUTPUT_DMG\""
    echo "    4. Tools/Release/release-flow.sh update-appcast --tag v${VERSION} --dmg \"$OUTPUT_DMG\" --download-url <browser-download-url>"
    echo "    5. git add Tools/Release/appcast.xml && git commit -m 'Release v${VERSION}' && git push"
    echo "    6. Tools/Release/release-flow.sh verify-remote --tag v${VERSION} --version ${VERSION} --build ${BUILD} --asset-sha256 <sha256> --asset-bytes <bytes>"
fi
