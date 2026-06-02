#!/usr/bin/env bash
# Copyright (c) 2026 DGPisces. Licensed under MIT — see LICENSE at repo root.
set -euo pipefail

TARGET="${HOME}/.bough/claude-usage.json"
mkdir -p "$(dirname "${TARGET}")"

if ! NEW="$(jq -c '{version, rate_limits, output_style, model}' 2>/dev/null)"; then
  echo " "
  exit 0
fi

if [ -f "${TARGET}" ]; then
  OLD_RATE="$(jq -c '.rate_limits' "${TARGET}" 2>/dev/null || true)"
  NEW_RATE="$(echo "${NEW}" | jq -c '.rate_limits' 2>/dev/null || true)"
  if [ "${OLD_RATE}" = "${NEW_RATE}" ]; then
    touch "${TARGET}"
    echo " "
    exit 0
  fi
fi

TMP="$(mktemp "${TARGET}.XXXXXX")"
echo "${NEW}" > "${TMP}"
mv -f "${TMP}" "${TARGET}"
echo " "
