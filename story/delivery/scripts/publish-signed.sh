#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STEP_FILE=""
SIGNED_TX_FILE=""
RPC_URL="${RPC_URL:-}"

usage() {
  cat <<EOF
Usage:
  publish-signed.sh --step <step.json> --signed-tx-file <file> [--rpc-url <url>]

Verifies the signed transaction matches the step manifest, broadcasts it,
and verifies the postcondition defined in the step JSON.

Options:
  --step <file>          Path to the step JSON file produced by deploy.sh --mode=unsigned
  --signed-tx-file <file>  Path to a file containing the signed raw tx hex
  --rpc-url <url>        RPC URL (or set RPC_URL env var)
  -h, --help             Show this help text
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --step)
      STEP_FILE="$2"
      shift 2
      ;;
    --signed-tx-file)
      SIGNED_TX_FILE="$2"
      shift 2
      ;;
    --rpc-url)
      RPC_URL="$2"
      shift 2
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

if [[ -z "$SIGNED_TX_FILE" ]]; then
  echo "--signed-tx-file is required" >&2
  usage
fi

if [[ -z "$RPC_URL" ]]; then
  echo "RPC_URL is required (set env var or pass --rpc-url)" >&2
  usage
fi

if [[ ! -f "$STEP_FILE" ]]; then
  echo "step file not found: $STEP_FILE" >&2
  exit 1
fi

if [[ ! -f "$SIGNED_TX_FILE" ]]; then
  echo "signed tx file not found: $SIGNED_TX_FILE" >&2
  exit 1
fi

SIGNED_TX="$(cat "$SIGNED_TX_FILE" | tr -d '[:space:]')"

if [[ -z "$SIGNED_TX" ]]; then
  echo "signed tx file is empty: $SIGNED_TX_FILE" >&2
  exit 1
fi

STEP_NAME="$(rtk bun -e "const s=require('$STEP_FILE');console.log(s.stepName||'unknown')" 2>/dev/null || echo 'unknown')"
STEP_INDEX="$(rtk bun -e "const s=require('$STEP_FILE');console.log(s.stepIndex||0)" 2>/dev/null || echo '0')"
STEP_KIND="$(rtk bun -e "const s=require('$STEP_FILE');console.log(s.kind||'unknown')" 2>/dev/null || echo 'unknown')"
STEP_CHAIN_ID="$(rtk bun -e "const s=require('$STEP_FILE');console.log(s.chainId ?? '')" 2>/dev/null || echo '')"
STEP_FROM="$(rtk bun -e "const s=require('$STEP_FILE');console.log((s.from||'').toLowerCase())" 2>/dev/null || echo '')"
STEP_NONCE="$(rtk bun -e "const s=require('$STEP_FILE');console.log(s.nonce||0)" 2>/dev/null || echo '0')"
STEP_TO="$(rtk bun -e "const s=require('$STEP_FILE');const v=s.to;console.log(v == null ? '' : v)" 2>/dev/null || echo '')"
STEP_DATA="$(rtk bun -e "const s=require('$STEP_FILE');console.log((s.data||'0x').toLowerCase())" 2>/dev/null || echo '0x')"

echo "step $STEP_INDEX ($STEP_NAME, kind=$STEP_KIND)..." >&2
echo "  manifest chainId: ${STEP_CHAIN_ID:-unknown} nonce: $STEP_NONCE  to: ${STEP_TO:-<create>}" >&2

# --- Pre-broadcast verification ---

DECODED_JSON="$(rtk bun "$ROOT_DIR/scripts/decode-signed-tx.mjs" "$SIGNED_TX" 2>/dev/null || true)"

if [[ -z "$DECODED_JSON" ]]; then
  echo "FAIL  could not decode signed transaction" >&2
  exit 1
else
  DECODED_CHAIN_ID="$(rtk bun -e "const tx=JSON.parse(process.argv[1]); console.log(tx.chainId ?? '')" "$DECODED_JSON" 2>/dev/null || echo '')"
  DECODED_FROM="$(rtk bun -e "const tx=JSON.parse(process.argv[1]); console.log(tx.from ?? '')" "$DECODED_JSON" 2>/dev/null || echo '')"
  DECODED_NONCE="$(rtk bun -e "const tx=JSON.parse(process.argv[1]); console.log(tx.nonce ?? '')" "$DECODED_JSON" 2>/dev/null || echo '')"
  DECODED_TO="$(rtk bun -e "const tx=JSON.parse(process.argv[1]); console.log(tx.to ?? '')" "$DECODED_JSON" 2>/dev/null || echo '')"
  DECODED_DATA="$(rtk bun -e "const tx=JSON.parse(process.argv[1]); console.log((tx.data || '0x').toLowerCase())" "$DECODED_JSON" 2>/dev/null || echo '')"

  if [[ -n "$STEP_CHAIN_ID" && -n "$DECODED_CHAIN_ID" ]]; then
    if [[ "$DECODED_CHAIN_ID" != "$STEP_CHAIN_ID" ]]; then
      echo "FAIL  chainId mismatch: signed tx has chainId $DECODED_CHAIN_ID, step manifest expects $STEP_CHAIN_ID" >&2
      exit 1
    fi
    echo "  ok   chainId matches: $STEP_CHAIN_ID" >&2
  fi

  if [[ -n "$STEP_FROM" && -n "$DECODED_FROM" ]]; then
    if [[ "$DECODED_FROM" != "$STEP_FROM" ]]; then
      echo "FAIL  sender mismatch: signed tx is from $DECODED_FROM, step manifest expects $STEP_FROM" >&2
      exit 1
    fi
    echo "  ok   sender matches: $STEP_FROM" >&2
  fi

  if [[ -n "$DECODED_NONCE" ]]; then
    if [[ "$DECODED_NONCE" != "$STEP_NONCE" ]]; then
      echo "FAIL  nonce mismatch: signed tx has nonce $DECODED_NONCE, step manifest expects $STEP_NONCE" >&2
      exit 1
    fi
    echo "  ok   nonce matches: $STEP_NONCE" >&2
  fi

  if [[ -n "$STEP_TO" ]]; then
    DECODED_TO_NORM="$(echo "${DECODED_TO:-}" | tr '[:upper:]' '[:lower:]')"
    STEP_TO_NORM="$(echo "$STEP_TO" | tr '[:upper:]' '[:lower:]')"
    if [[ "$DECODED_TO_NORM" != "$STEP_TO_NORM" ]]; then
      echo "FAIL  to address mismatch: signed tx has ${DECODED_TO:-<create>}, step manifest expects $STEP_TO" >&2
      exit 1
    fi
    echo "  ok   to address matches: $STEP_TO" >&2
  elif [[ "$STEP_KIND" == "create" && -n "$DECODED_TO" ]]; then
    echo "FAIL  create step expected no to address, signed tx has $DECODED_TO" >&2
    exit 1
  fi

  if [[ -n "$DECODED_DATA" ]]; then
    STEP_DATA_NORM="$(echo "$STEP_DATA" | tr '[:upper:]' '[:lower:]')"
    if [[ "$DECODED_DATA" != "$STEP_DATA_NORM" ]]; then
      echo "FAIL  data mismatch between signed tx and step manifest" >&2
      exit 1
    fi
    echo "  ok   data matches manifest" >&2
  fi
fi

# --- Broadcast ---

echo "broadcasting..." >&2

TX_HASH="$(rtk cast publish "$SIGNED_TX" --rpc-url "$RPC_URL" 2>&1)"

if [[ -z "$TX_HASH" ]]; then
  echo "FAIL  broadcast returned empty tx hash" >&2
  exit 1
fi

echo "  tx hash: $TX_HASH" >&2

RECEIPT_WAIT_SECONDS="${RECEIPT_WAIT_SECONDS:-5}"
sleep "$RECEIPT_WAIT_SECONDS"

BLOCK_NUMBER=""
TX_STATUS=""
set +e
RECEIPT="$(rtk cast receipt "$TX_HASH" --rpc-url "$RPC_URL" 2>&1)"
set -e

if [[ -n "$RECEIPT" ]]; then
  BLOCK_NUMBER="$(echo "$RECEIPT" | grep -oP 'blockNumber\s+\K\d+' || echo "unknown")"
  TX_STATUS="$(echo "$RECEIPT" | grep -oP 'status\s+\K\S+' || echo "unknown")"
  echo "  block: $BLOCK_NUMBER  status: $TX_STATUS" >&2
fi

# --- Postcondition verification ---

POST_CHECK_TYPE="$(rtk bun -e "const s=require('$STEP_FILE');console.log(s.postCheck?.type||'none')" 2>/dev/null || echo 'none')"

echo "" >&2
echo "verifying postcondition ($POST_CHECK_TYPE)..." >&2

case "$POST_CHECK_TYPE" in
  code_exists)
    CHECK_ADDR="$(rtk bun -e "const s=require('$STEP_FILE');console.log(s.postCheck?.address||s.expectedContractAddress||'')" 2>/dev/null)"
    if [[ -z "$CHECK_ADDR" ]]; then
      echo "WARN  no address to check for code_exists" >&2
    else
      CODE="$(rtk cast code "$CHECK_ADDR" --rpc-url "$RPC_URL" 2>/dev/null)"
      if [[ "$CODE" != "0x" ]]; then
        echo "  ok   code exists at $CHECK_ADDR" >&2
      else
        echo "FAIL  no code at $CHECK_ADDR" >&2
        exit 1
      fi
    fi
    ;;
  bool_check)
    CHECK_TARGET="$(rtk bun -e "const s=require('$STEP_FILE');console.log(s.postCheck?.target||'')" 2>/dev/null)"
    CHECK_SIG="$(rtk bun -e "const s=require('$STEP_FILE');console.log(s.postCheck?.signature||'')" 2>/dev/null)"
    CHECK_ARG="$(rtk bun -e "const s=require('$STEP_FILE');console.log(s.postCheck?.argument||'')" 2>/dev/null)"
    CHECK_EXPECTED="$(rtk bun -e "const s=require('$STEP_FILE');console.log(s.postCheck?.expected||'')" 2>/dev/null)"

    if [[ -z "$CHECK_TARGET" || -z "$CHECK_SIG" ]]; then
      echo "WARN  incomplete bool_check in step JSON" >&2
    else
      RESULT="$(rtk cast call "$CHECK_TARGET" "$CHECK_SIG" "$CHECK_ARG" --rpc-url "$RPC_URL" 2>/dev/null)"
      if [[ "$RESULT" == "$CHECK_EXPECTED" ]]; then
        echo "  ok   $CHECK_SIG($CHECK_ARG) == $CHECK_EXPECTED" >&2
      else
        echo "FAIL  $CHECK_SIG($CHECK_ARG) == $RESULT, expected $CHECK_EXPECTED" >&2
        exit 1
      fi
    fi
    ;;
  owner_check)
    CHECK_TARGET="$(rtk bun -e "const s=require('$STEP_FILE');console.log(s.postCheck?.target||'')" 2>/dev/null)"
    CHECK_OWNER="$(rtk bun -e "const s=require('$STEP_FILE');console.log(s.postCheck?.expectedOwner||'')" 2>/dev/null)"

    if [[ -z "$CHECK_TARGET" || -z "$CHECK_OWNER" ]]; then
      echo "WARN  incomplete owner_check in step JSON" >&2
    else
      RESULT="$(rtk cast call "$CHECK_TARGET" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null)"
      if [[ "$RESULT" == "$CHECK_OWNER" ]]; then
        echo "  ok   owner($CHECK_TARGET) == $CHECK_OWNER" >&2
      else
        echo "FAIL  owner($CHECK_TARGET) == $RESULT, expected $CHECK_OWNER" >&2
        exit 1
      fi
    fi
    ;;
  none)
    echo "  --   no postcondition defined" >&2
    ;;
  *)
    echo "WARN  unknown postCheck type: $POST_CHECK_TYPE" >&2
    ;;
esac

# --- Persist status ---

PUBLISH_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

rtk bun -e "
const fs = require('fs');
const step = JSON.parse(fs.readFileSync('$STEP_FILE', 'utf8'));
step.status = step.status || {};
step.status.signed = true;
step.status.published = true;
step.status.publishedAt = '$PUBLISH_TS';
step.status.txHash = '$TX_HASH';
step.status.blockNumber = '$BLOCK_NUMBER';
step.status.verified = true;
fs.writeFileSync('$STEP_FILE', JSON.stringify(step, null, 2) + '\n');
console.log('updated step status');
" 2>/dev/null

echo "" >&2
echo "step $STEP_INDEX ($STEP_NAME) complete" >&2
