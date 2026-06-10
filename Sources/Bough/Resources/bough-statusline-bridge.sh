#!/usr/bin/env bash
# Copyright (c) 2026 DGPisces. Licensed under MIT — see LICENSE at repo root.
set -euo pipefail

TARGET="${HOME}/.bough/claude-usage.json"
mkdir -p "$(dirname "${TARGET}")"
chmod 700 "$(dirname "${TARGET}")" 2>/dev/null || true

PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
elif [ -x /usr/bin/python3 ]; then
  PYTHON_BIN="/usr/bin/python3"
fi

if [ -z "${PYTHON_BIN}" ]; then
  echo "bough-statusline-bridge: python3 not found" >&2
  echo " "
  exit 0
fi

"${PYTHON_BIN}" -c '
import json
import os
import sys
import tempfile

target = sys.argv[1]
keys = ("version", "rate_limits", "output_style", "model")

try:
    root = json.load(sys.stdin)
except Exception:
    sys.exit(0)

payload = {key: root.get(key) for key in keys}
new_text = json.dumps(payload, separators=(",", ":"), sort_keys=True)

try:
    with open(target, "r", encoding="utf-8") as handle:
        old_root = json.load(handle)
    old_payload = {key: old_root.get(key) for key in keys}
    old_text = json.dumps(old_payload, separators=(",", ":"), sort_keys=True)
except Exception:
    old_text = None

if old_text == new_text:
    try:
        os.chmod(target, 0o600)
    except Exception:
        pass
    try:
        os.utime(target, None)
    except Exception:
        pass
    sys.exit(0)

directory = os.path.dirname(target)
os.makedirs(directory, mode=0o700, exist_ok=True)
try:
    os.chmod(directory, 0o700)
except Exception:
    pass

fd, tmp = tempfile.mkstemp(prefix=os.path.basename(target) + ".", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(new_text)
        handle.write("\n")
    try:
        os.chmod(tmp, 0o600)
    except Exception:
        pass
    os.replace(tmp, target)
    try:
        os.chmod(target, 0o600)
    except Exception:
        pass
except Exception:
    try:
        os.unlink(tmp)
    except Exception:
        pass
' "${TARGET}"
echo " "
