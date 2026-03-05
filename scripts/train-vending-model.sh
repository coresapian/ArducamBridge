#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATASET_PATH="${1:?dataset path required}"
BACKEND="${2:-yolo}"
WEIGHTS_PATH="${3:-yolo26n.pt}"
EPOCHS="${4:-40}"
IMGSZ="${5:-960}"
BATCH_SIZE="${6:-8}"
RUN_NAME="${7:-vending-products}"
PROJECT_DIR="${8:-${ROOT_DIR}/runs/vending-training}"
DEVICE_NAME="${9:-auto}"
VALIDATE_ONLY="${10:-0}"

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

ARGS=(
  run --project "${ROOT_DIR}" python "${ROOT_DIR}/vision/train_vending_model.py"
  --dataset-root "${DATASET_PATH}"
  --backend "${BACKEND}"
  --weights "${WEIGHTS_PATH}"
  --epochs "${EPOCHS}"
  --imgsz "${IMGSZ}"
  --batch-size "${BATCH_SIZE}"
  --run-name "${RUN_NAME}"
  --project-dir "${PROJECT_DIR}"
  --device "${DEVICE_NAME}"
)

if [[ "${VALIDATE_ONLY}" == "1" ]]; then
  ARGS+=(--validate-only)
fi

exec "${UV_BIN}" "${ARGS[@]}"
