#!/usr/bin/env bash
# regenerate-app-icon.sh
# Regenerates Platform/Apple/Assets.xcassets/AppIcon.appiconset/*.png and
# Sources/Bough/Resources/AppIcon.icns from the canonical 1024×1024 master at
# Platform/Apple/icon-source/icon-master-1024.png.
#
# WHY THIS SCRIPT EXISTS (load-bearing context)
# --------------------------------------------
# Bough deliberately uses the classical macOS AppIcon.appiconset format instead
# of the Xcode 26 .icon (Icon Composer) format. The .icon format requires a
# tile "fill" (e.g. "system-light" or "system-dark") which actool composites
# under the foreground design — that fill leaks a visible halo ring between
# the design's bounding edge and the rounded-rect mask edge in the dock.
# Usage (from repo root):
#   ./Tools/Build/regenerate-app-icon.sh
set -euo pipefail

SRC="Platform/Apple/icon-source/icon-master-1024.png"
OUTDIR="Platform/Apple/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$SRC" ]; then
    echo "ERROR: master not found at $SRC" >&2
    exit 1
fi

# Verify master is 1024x1024 (sips will silently up/downscale otherwise).
SIZE=$(sips -g pixelWidth -g pixelHeight "$SRC" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w"x"h}')
if [ "$SIZE" != "1024x1024" ]; then
    echo "ERROR: $SRC is $SIZE; expected 1024x1024" >&2
    exit 1
fi

mkdir -p "$OUTDIR"

sips -z 16   16   "$SRC" --out "$OUTDIR/icon_16x16.png"      >/dev/null
sips -z 32   32   "$SRC" --out "$OUTDIR/icon_16x16@2x.png"   >/dev/null
sips -z 32   32   "$SRC" --out "$OUTDIR/icon_32x32.png"      >/dev/null
sips -z 64   64   "$SRC" --out "$OUTDIR/icon_32x32@2x.png"   >/dev/null
sips -z 128  128  "$SRC" --out "$OUTDIR/icon_128x128.png"    >/dev/null
sips -z 256  256  "$SRC" --out "$OUTDIR/icon_128x128@2x.png" >/dev/null
sips -z 256  256  "$SRC" --out "$OUTDIR/icon_256x256.png"    >/dev/null
sips -z 512  512  "$SRC" --out "$OUTDIR/icon_256x256@2x.png" >/dev/null
sips -z 512  512  "$SRC" --out "$OUTDIR/icon_512x512.png"    >/dev/null
sips -z 1024 1024 "$SRC" --out "$OUTDIR/icon_512x512@2x.png" >/dev/null

# Bake Sources/Bough/Resources/AppIcon.icns so the SPM resource bundle copy
# stays consistent with the actool-compiled bundle copy.
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
cp -R "$OUTDIR" "$TMPDIR/AppIcon.iconset"
iconutil -c icns -o "Sources/Bough/Resources/AppIcon.icns" "$TMPDIR/AppIcon.iconset"

echo "Regenerated:"
echo "  $OUTDIR/*.png (10 sizes)"
echo "  Sources/Bough/Resources/AppIcon.icns"
