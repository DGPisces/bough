#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="${APP_DIR:-$REPO_ROOT/.build/dmg-staging/Bough.app}"
HELPER="$APP_DIR/Contents/Helpers/bough-usage-monitor"
PLIST="$APP_DIR/Contents/Library/LaunchAgents/dev.dgpisces.bough.usage-monitor.plist"
DMG="${DMG:-$REPO_ROOT/.build/Bough.dmg}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

echo "==> Packaged usage monitor smoke"
echo "app=$APP_DIR"

[ -d "$APP_DIR" ] || fail "staged app not found; run Tools/Build/build-dmg.sh first"
[ -x "$HELPER" ] || fail "packaged helper missing or not executable: $HELPER"
[ -f "$PLIST" ] || fail "packaged LaunchAgent plist missing: $PLIST"

plutil -lint "$PLIST" >/dev/null
BUNDLE_PROGRAM="$(plutil -extract BundleProgram raw "$PLIST")"
[ "$BUNDLE_PROGRAM" = "Contents/Helpers/bough-usage-monitor" ] \
    || fail "LaunchAgent BundleProgram mismatch: $BUNDLE_PROGRAM"
echo "plist=ok"
echo "helper=ok"

if [ "${REQUIRE_SIGNED:-0}" = "1" ]; then
    codesign --verify --deep --strict --verbose=2 "$APP_DIR" >/dev/null
    codesign --verify --strict --verbose=2 "$HELPER" >/dev/null
    echo "codesign=ok"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bough-packaged-monitor.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FIXTURE="$TMP_DIR/claude-usage.json"
STATUS="$TMP_DIR/usage-monitor-status.json"
CONTINUITY="$TMP_DIR/usage-continuity.sqlite"
COMMAND="$TMP_DIR/usage-monitor-command.json"

cat >"$FIXTURE" <<'JSON'
{
  "version": 1,
  "model": "sonnet",
  "rate_limits": {
    "five_hour": {
      "used_percentage": 12,
      "resets_at": 1779201600
    },
    "seven_day": {
      "used_percentage": 34,
      "resets_at": 1779806400
    }
  }
}
JSON

cat >"$COMMAND" <<'JSON'
{
  "enabledTools": ["claudeCode"]
}
JSON

"$HELPER" \
    --once \
    --status-path "$STATUS" \
    --continuity-path "$CONTINUITY" \
    --command-path "$COMMAND" \
    --claude-usage-path "$FIXTURE"

[ -s "$STATUS" ] || fail "helper did not write status JSON"
[ -s "$CONTINUITY" ] || fail "helper did not write continuity store"

STATE="$(plutil -extract state raw "$STATUS")"
OWNER="$(plutil -extract writerOwner raw "$STATUS")"
TOOL="$(plutil -extract lastAcceptedTool raw "$STATUS")"
[ "$STATE" = "running" ] || fail "unexpected helper status state: $STATE"
[ "$OWNER" = "helper" ] || fail "unexpected writer owner: $OWNER"
[ "$TOOL" = "claudeCode" ] || fail "unexpected accepted tool: $TOOL"

if grep -Eiq '"(prompt|transcript|command|filePath|path)"[[:space:]]*:' "$STATUS"; then
    fail "status JSON contains forbidden private-content keys"
fi

ACCEPTED_COUNT="$(sqlite3 "$CONTINUITY" "SELECT COUNT(*) FROM accepted_samples WHERE tool = 'claudeCode';")"
[ "$ACCEPTED_COUNT" = "1" ] || fail "expected one accepted claudeCode sample, got $ACCEPTED_COUNT"

echo "status=running"
echo "writerOwner=helper"
echo "acceptedSamples=$ACCEPTED_COUNT"

if [ -f "$DMG" ]; then
    DMG_SIZE="$(stat -f %z "$DMG")"
    DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
    echo "dmg=$DMG"
    echo "dmgBytes=$DMG_SIZE"
    echo "dmgSha256=$DMG_SHA256"
fi

echo "==> Packaged usage monitor smoke passed"
