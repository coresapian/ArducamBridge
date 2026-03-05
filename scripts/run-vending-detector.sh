#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_PATH="${1:-${ROOT_DIR}/configs/vending.example.yaml}"

UV_BIN="${UV_BIN:-}"
if [[ -z "${UV_BIN}" ]]; then
  if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
  else
    for candidate in /opt/homebrew/bin/uv /usr/local/bin/uv; do
      if [[ -x "${candidate}" ]]; then
        UV_BIN="${candidate}"
        break
      fi
    done
  fi
fi

if [[ -z "${UV_BIN}" ]]; then
  echo "uv executable not found. Install uv or set UV_BIN." >&2
  exit 1
fi

exec "${UV_BIN}" run --project "${ROOT_DIR}" python "${ROOT_DIR}/vision/vending_tracker_service.py" --config "${CONFIG_PATH}"
