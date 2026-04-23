#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$ROOT_DIR/../../.." && pwd)"

STEP_FILE=""
OUTPUT_FILE=""
OUTPUT_TYPE="svg"
SMALL_TERMINAL="0"
MAX_STATIC_QR_CHARS="${MAX_STATIC_QR_CHARS:-2953}"
QRCODE_BIN="${QRCODE_BIN:-}"

usage() {
  cat <<EOF
Usage:
  render-step-qr.sh --step <step.json> [--output <file>] [--type svg|png|utf8] [--small]

Renders the step's unsignedRawTx as a single static QR code when it fits.
If the unsigned transaction is too large for a single QR, the script fails
with a clear message instead of producing an unreliable code.

Options:
  --step <file>      Path to the step JSON file produced by deploy.sh MODE=unsigned
  --output <file>    Output file path for svg/png modes
  --type <type>      One of: svg, png, utf8 (default: svg)
  --small            Use the qrcode CLI's smaller terminal output mode for utf8
  -h, --help         Show this help text

Environment:
  MAX_STATIC_QR_CHARS  Maximum unsignedRawTx character length to allow in a single static QR
                       Default: 2953
  QRCODE_BIN           Override the qrcode CLI path
EOF
  exit 1
}

find_qrcode_bin() {
  if [[ -n "$QRCODE_BIN" ]]; then
    printf '%s\n' "$QRCODE_BIN"
    return 0
  fi

  local candidate=""
  for candidate in \
    "$WORKSPACE_ROOT/web/node_modules/.bin/qrcode" \
    "$WORKSPACE_ROOT/pirate-web/node_modules/.bin/qrcode"
  do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if command -v qrcode >/dev/null 2>&1; then
    command -v qrcode
    return 0
  fi

  echo "could not find qrcode CLI; expected $candidate or qrcode on PATH" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --step)
      STEP_FILE="$2"
      shift 2
      ;;
    --output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --type)
      OUTPUT_TYPE="$2"
      shift 2
      ;;
    --small)
      SMALL_TERMINAL="1"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [[ -z "$STEP_FILE" ]]; then
  echo "--step is required" >&2
  usage
fi

if [[ ! -f "$STEP_FILE" ]]; then
  echo "step file not found: $STEP_FILE" >&2
  exit 1
fi

case "$OUTPUT_TYPE" in
  svg|png|utf8)
    ;;
  *)
    echo "--type must be one of: svg, png, utf8" >&2
    exit 1
    ;;
esac

if [[ "$OUTPUT_TYPE" != "utf8" && -z "$OUTPUT_FILE" ]]; then
  base_name="$(basename "$STEP_FILE" .json)"
  OUTPUT_FILE="$ROOT_DIR/deployments/qr/$base_name.$OUTPUT_TYPE"
fi

QRCODE_BIN="$(find_qrcode_bin)"

STEP_INFO="$(rtk bun -e "
  const fs = require('fs');
  const step = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
  const info = {
    stepIndex: step.stepIndex ?? null,
    stepName: step.stepName ?? '',
    kind: step.kind ?? '',
    unsignedRawTx: step.unsignedRawTx ?? '',
  };
  process.stdout.write(JSON.stringify(info));
" "$STEP_FILE")"

STEP_NAME="$(rtk bun -e "const info=JSON.parse(process.argv[1]); console.log(info.stepName || 'unknown')" "$STEP_INFO")"
STEP_INDEX="$(rtk bun -e "const info=JSON.parse(process.argv[1]); console.log(info.stepIndex ?? '')" "$STEP_INFO")"
STEP_KIND="$(rtk bun -e "const info=JSON.parse(process.argv[1]); console.log(info.kind || '')" "$STEP_INFO")"
UNSIGNED_RAW_TX="$(rtk bun -e "const info=JSON.parse(process.argv[1]); process.stdout.write(info.unsignedRawTx || '')" "$STEP_INFO")"
UNSIGNED_CHAR_COUNT="$(printf '%s' "$UNSIGNED_RAW_TX" | wc -c | tr -d ' ')"

if [[ -z "$UNSIGNED_RAW_TX" ]]; then
  echo "step JSON has no unsignedRawTx: $STEP_FILE" >&2
  exit 1
fi

if (( UNSIGNED_CHAR_COUNT > MAX_STATIC_QR_CHARS )); then
  echo "step ${STEP_INDEX:-?} ($STEP_NAME, kind=$STEP_KIND) is too large for a single static QR" >&2
  echo "  unsignedRawTx length: $UNSIGNED_CHAR_COUNT chars" >&2
  echo "  static QR limit:      $MAX_STATIC_QR_CHARS chars" >&2
  echo "  use file/microSD import or a future multipart/animated QR flow for this step" >&2
  exit 2
fi

if [[ "$OUTPUT_TYPE" == "utf8" ]]; then
  QR_ARGS=(-t utf8)
  if [[ "$SMALL_TERMINAL" == "1" ]]; then
    QR_ARGS+=(--small)
  fi
  echo "rendering step ${STEP_INDEX:-?} ($STEP_NAME) to terminal QR..." >&2
  rtk "$QRCODE_BIN" "${QR_ARGS[@]}" "$UNSIGNED_RAW_TX"
  exit 0
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

echo "rendering step ${STEP_INDEX:-?} ($STEP_NAME) to $OUTPUT_FILE..." >&2
rtk "$QRCODE_BIN" -t "$OUTPUT_TYPE" -o "$OUTPUT_FILE" "$UNSIGNED_RAW_TX" >/dev/null
echo "ok  wrote $OUTPUT_FILE" >&2
