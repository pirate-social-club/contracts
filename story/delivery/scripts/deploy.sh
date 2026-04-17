#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DEPLOY_TAG="${DEPLOY_TAG:-manual}"
FORCE_REDEPLOY="${FORCE_REDEPLOY:-0}"
LEGACY="${LEGACY:-0}"
MODE="${MODE:-hot}"
DEPLOYMENTS_DIR="$ROOT_DIR/deployments"
MANIFEST_PATH="$DEPLOYMENTS_DIR/$DEPLOY_TAG.env"
STEPS_DIR="$DEPLOYMENTS_DIR/$DEPLOY_TAG/steps"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "missing required env: $name" >&2
    exit 1
  fi
}

require_env RPC_URL
require_env PUBLISH_OPERATOR
require_env SETTLEMENT_OPERATOR
require_env ACCESS_PROOF_SIGNER

if [[ "$MODE" != "hot" && "$MODE" != "unsigned" ]]; then
  echo "MODE must be 'hot' or 'unsigned', got: $MODE" >&2
  exit 1
fi

if [[ "$MODE" == "hot" ]]; then
  require_env STORY_CONTRACT_OWNER_PRIVATE_KEY
  DEPLOYER_ADDRESS="$(rtk cast wallet address --private-key "$STORY_CONTRACT_OWNER_PRIVATE_KEY")"
else
  require_env DEPLOYER_ADDRESS
fi

mkdir -p "$DEPLOYMENTS_DIR"

if [[ -f "$MANIFEST_PATH" && "$FORCE_REDEPLOY" != "1" ]]; then
  # shellcheck disable=SC1090
  source "$MANIFEST_PATH"
  if [[ "${DELIVERY_DEPLOYMENT_COMPLETE:-0}" == "1" ]]; then
    echo "deployment manifest already exists and is marked complete: $MANIFEST_PATH" >&2
    echo "set FORCE_REDEPLOY=1 to overwrite it intentionally" >&2
    exit 1
  fi
  echo "resuming partial deployment from $MANIFEST_PATH" >&2
fi

TX_FLAGS=()
if [[ "$LEGACY" == "1" ]]; then
  TX_FLAGS+=(--legacy)
fi

write_manifest() {
  cat <<EOF >"$MANIFEST_PATH"
DELIVERY_DEPLOYMENT_COMPLETE=${DELIVERY_DEPLOYMENT_COMPLETE:-0}
MODE=$MODE
DEPLOY_TAG=$DEPLOY_TAG
RPC_URL=$RPC_URL
DEPLOYER_ADDRESS=$DEPLOYER_ADDRESS
PURCHASE_ENTITLEMENT_TOKEN=${PURCHASE_ENTITLEMENT_TOKEN:-}
PIRATE_SIGNER_REGISTRY=${PIRATE_SIGNER_REGISTRY:-}
TOKEN_GATE_CONDITION=${TOKEN_GATE_CONDITION:-}
SIGNED_ACCESS_CONDITION_V1=${SIGNED_ACCESS_CONDITION_V1:-}
ASSET_PUBLISH_COORDINATOR_V1=${ASSET_PUBLISH_COORDINATOR_V1:-}
MARKETPLACE_SETTLEMENT_V1=${MARKETPLACE_SETTLEMENT_V1:-}
PUBLISH_OPERATOR=$PUBLISH_OPERATOR
SETTLEMENT_OPERATOR=$SETTLEMENT_OPERATOR
ACCESS_PROOF_SIGNER=$ACCESS_PROOF_SIGNER
OWNER_ADDRESS=${OWNER_ADDRESS:-}
LEGACY=$LEGACY
EOF
}

has_code() {
  local address="$1"
  local code
  code="$(rtk cast code "$address" --rpc-url "$RPC_URL")"
  [[ "$code" != "0x" ]]
}

current_nonce() {
  rtk cast nonce "$DEPLOYER_ADDRESS" --rpc-url "$RPC_URL"
}

compute_create_address() {
  local nonce="$1"
  rtk cast compute-address "$DEPLOYER_ADDRESS" --nonce "$nonce" | sed -nE 's/^Computed Address: (0x[a-fA-F0-9]{40})$/\1/p'
}

chain_id() {
  rtk cast chain-id --rpc-url "$RPC_URL"
}

estimate_gas_price() {
  rtk cast gas-price --rpc-url "$RPC_URL"
}

step_counter=0
virtual_nonce=""

init_virtual_nonce() {
  if [[ "$MODE" == "unsigned" && -z "$virtual_nonce" ]]; then
    virtual_nonce="$(current_nonce)"
  fi
}

next_step_counter() {
  step_counter=$((step_counter + 1))
}

next_virtual_nonce() {
  _VNONCE="$virtual_nonce"
  virtual_nonce=$((virtual_nonce + 1))
}

write_step_json() {
  local file_path="$1"
  shift
  local json_content="$*"

  if [[ "$MODE" != "unsigned" ]]; then
    return
  fi

  mkdir -p "$STEPS_DIR"
  printf '%s\n' "$json_content" > "$file_path"
  echo "  wrote $file_path" >&2
}

build_creation_code() {
  local contract="$1"
  shift || true

  local sol_name contract_name
  sol_name="$(basename "${contract%%:*}")"
  contract_name="${contract##*:}"

  local artifact_path="$ROOT_DIR/out/$sol_name/$contract_name.json"
  if [[ ! -f "$artifact_path" ]]; then
    echo "artifact not found: $artifact_path" >&2
    exit 1
  fi

  local bytecode
  bytecode="$(rtk bun -e "
    const f = require('$artifact_path');
    console.log(f.bytecode.object);
  " 2>/dev/null)"

  if [[ -z "$bytecode" ]]; then
    echo "could not extract bytecode from $artifact_path" >&2
    exit 1
  fi

  local creation_code="$bytecode"

  if [[ $# -gt 0 ]]; then
    local constructor_sig="$1"
    shift
    local encoded_args
    encoded_args="$(rtk cast abi-encode "$constructor_sig" "$@")"
    creation_code="${bytecode}${encoded_args#0x}"
  fi

  printf '%s' "$creation_code"
}

# --- Hot mode primitives ---

send_tx() {
  local to="$1"
  local sig="$2"
  shift 2

  local output
  if ! output="$(
    rtk cast send \
      --async \
      "$to" \
      "$sig" \
      "$@" \
      "${TX_FLAGS[@]}" \
      --rpc-url "$RPC_URL" \
      --private-key "$STORY_CONTRACT_OWNER_PRIVATE_KEY" 2>&1
  )"; then
    printf '%s\n' "$output" >&2
    return 1
  fi
  printf '%s\n' "$output" >&2
}

deploy_contract_hot() {
  local contract="$1"
  shift

  local pre_nonce post_nonce output status deployed
  pre_nonce="$(current_nonce)"

  set +e
  output="$(
    rtk forge create \
      "$contract" \
      --broadcast \
      --rpc-url "$RPC_URL" \
      --private-key "$STORY_CONTRACT_OWNER_PRIVATE_KEY" \
      "${TX_FLAGS[@]}" \
      "$@" 2>&1
  )"
  status=$?
  set -e

  printf '%s\n' "$output" >&2

  deployed="$(
    printf '%s\n' "$output" |
      sed -nE 's/.*Deployed to: (0x[a-fA-F0-9]{40}).*/\1/p' |
      tail -n1
  )"

  post_nonce="$(current_nonce)"

  if [[ -z "$deployed" && "$post_nonce" == "$((pre_nonce + 1))" ]]; then
    deployed="$(compute_create_address "$pre_nonce")"
    if [[ -n "$deployed" ]]; then
      echo "forge create did not return an address; derived deployed address from nonce $pre_nonce: $deployed" >&2
    fi
  fi

  if [[ -n "$deployed" ]] && has_code "$deployed"; then
    printf '%s\n' "$deployed"
    return 0
  fi

  echo "deployment failed for $contract (status=$status, pre_nonce=$pre_nonce, post_nonce=$post_nonce)" >&2
  return 1
}

wait_for_bool() {
  local target="$1"
  local check_sig="$2"
  local check_arg="$3"
  local expected="$4"
  local attempts="${5:-30}"
  local delay_secs="${6:-2}"
  local current

  for ((i=0; i<attempts; i++)); do
    current="$(rtk cast call "$target" "$check_sig" "$check_arg" --rpc-url "$RPC_URL")"
    if [[ "$current" == "$expected" ]]; then
      return 0
    fi
    sleep "$delay_secs"
  done

  echo "timed out waiting for $check_sig on $target to become $expected" >&2
  return 1
}

wait_for_owner() {
  local target="$1"
  local expected_owner="$2"
  local attempts="${3:-30}"
  local delay_secs="${4:-2}"
  local current_owner

  for ((i=0; i<attempts; i++)); do
    current_owner="$(rtk cast call "$target" "owner()(address)" --rpc-url "$RPC_URL")"
    if [[ "$current_owner" == "$expected_owner" ]]; then
      return 0
    fi
    sleep "$delay_secs"
  done

  echo "timed out waiting for owner($target) to become $expected_owner" >&2
  return 1
}

# --- Unsigned mode primitives ---

make_unsigned_call_tx() {
  local to="$1"
  local sig="$2"
  local nonce="$3"
  shift 3

  local gas_limit gas_price
  gas_limit="${GAS_LIMIT:-200000}"
  gas_price="$(estimate_gas_price)"

  local unsigned_raw
  unsigned_raw="$(rtk cast mktx \
    --raw-unsigned \
    "$to" \
    "$sig" \
    "$@" \
    --from "$DEPLOYER_ADDRESS" \
    --nonce "$nonce" \
    --gas-limit "$gas_limit" \
    --gas-price "$gas_price" \
    "${TX_FLAGS[@]}" \
    --rpc-url "$RPC_URL" 2>&1)"

  printf '%s' "$unsigned_raw"
}

make_unsigned_create_tx() {
  local contract="$1"
  local nonce="$2"
  local constructor_sig="${3:-}"
  shift 3 || true

  local gas_limit gas_price creation_code
  gas_limit="${GAS_LIMIT:-5000000}"
  gas_price="$(estimate_gas_price)"

  if [[ -n "$constructor_sig" ]]; then
    creation_code="$(build_creation_code "$contract" "$constructor_sig" "$@")"
  else
    creation_code="$(build_creation_code "$contract")"
  fi

  local unsigned_raw
  unsigned_raw="$(rtk cast mktx \
    --raw-unsigned \
    --from "$DEPLOYER_ADDRESS" \
    --nonce "$nonce" \
    --gas-limit "$gas_limit" \
    --gas-price "$gas_price" \
    "${TX_FLAGS[@]}" \
    --rpc-url "$RPC_URL" \
    --create "$creation_code" 2>&1)"

  printf '%s' "$unsigned_raw"
}

emit_create_step() {
  local step_name="$1"
  local contract="$2"
  local var_name="$3"
  local constructor_sig="${4:-}"
  shift 4 || true

  if [[ "$MODE" != "unsigned" ]]; then
    return
  fi

  next_step_counter
  local idx="$step_counter"
  next_virtual_nonce
  local nonce="$_VNONCE"
  local gas_limit="${GAS_LIMIT:-5000000}"
  local gas_price
  gas_price="$(estimate_gas_price)"
  local chain
  chain="$(chain_id)"

  local creation_code
  if [[ -n "$constructor_sig" ]]; then
    creation_code="$(build_creation_code "$contract" "$constructor_sig" "$@")"
  else
    creation_code="$(build_creation_code "$contract")"
  fi

  local predicted_address
  predicted_address="$(compute_create_address "$nonce")"

  local file_name
  printf -v file_name '%03d-%s.create.json' "$idx" "$step_name"
  local file_path="$STEPS_DIR/$file_name"

  local human_summary="Deploy $contract"
  if [[ -n "$constructor_sig" ]]; then
    human_summary="$human_summary with constructor $constructor_sig"
  fi

  local fee_model="eip1559"
  local legacy_flag="false"
  if [[ "$LEGACY" == "1" ]]; then
    fee_model="legacy"
    legacy_flag="true"
  fi

  local unsigned_raw
  if [[ -n "$constructor_sig" ]]; then
    unsigned_raw="$(make_unsigned_create_tx "$contract" "$nonce" "$constructor_sig" "$@" 2>/dev/null)"
  else
    unsigned_raw="$(make_unsigned_create_tx "$contract" "$nonce" 2>/dev/null)"
  fi

  mkdir -p "$STEPS_DIR"
  cat <<EOF | tee "$file_path"
{
  "stepIndex": $idx,
  "stepName": "$step_name",
  "kind": "create",
  "contract": "$contract",
  "from": "$DEPLOYER_ADDRESS",
  "nonce": $nonce,
  "chainId": $chain,
  "feeModel": "$fee_model",
  "gasLimit": $gas_limit,
  "gasPrice": "$gas_price",
  "maxFeePerGas": null,
  "maxPriorityFeePerGas": null,
  "to": null,
  "value": "0x0",
  "data": "$creation_code",
  "unsignedRawTx": "$unsigned_raw",
  "expectedContractAddress": "$predicted_address",
  "assignToVar": "$var_name",
  "postCheck": {
    "type": "code_exists",
    "address": "$predicted_address"
  },
  "dependsOn": [],
  "legacy": $legacy_flag,
  "humanSummary": "$human_summary",
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  printf -v "$var_name" '%s' "$predicted_address"
  write_manifest
}

emit_call_step() {
  local step_name="$1"
  local target="$2"
  local sig="$3"
  shift 3

  local check_type="${1:-}"
  shift || true

  local check_target="$target"
  local check_sig=""
  local check_arg=""
  local expected=""

  if [[ "$check_type" == "bool_grant" ]]; then
    check_target="$1"
    check_sig="$2"
    check_arg="$3"
    expected="$4"
    shift 4
  fi

  if [[ "$MODE" != "unsigned" ]]; then
    return
  fi

  next_step_counter
  local idx="$step_counter"
  next_virtual_nonce
  local nonce="$_VNONCE"
  local gas_limit="${GAS_LIMIT:-200000}"
  local gas_price
  gas_price="$(estimate_gas_price)"
  local chain
  chain="$(chain_id)"

  local file_name
  printf -v file_name '%03d-%s.call.json' "$idx" "$step_name"
  local file_path="$STEPS_DIR/$file_name"

  local fee_model="eip1559"
  local legacy_flag="false"
  if [[ "$LEGACY" == "1" ]]; then
    fee_model="legacy"
    legacy_flag="true"
  fi

  local post_check_json
  if [[ "$check_type" == "bool_grant" ]]; then
    post_check_json=$(cat <<CHECKEOF
{
    "type": "bool_check",
    "target": "$check_target",
    "signature": "$check_sig",
    "argument": "$check_arg",
    "expected": "$expected"
  }
CHECKEOF
)
  elif [[ "$check_type" == "owner_transfer" ]]; then
    post_check_json=$(cat <<CHECKEOF
{
    "type": "owner_check",
    "target": "$target",
    "expectedOwner": "$1"
  }
CHECKEOF
)
  else
    post_check_json='{"type": "none"}'
  fi

  local calldata
  calldata="$(rtk cast calldata "$sig" "$@" 2>/dev/null || echo "")"

  local unsigned_raw
  unsigned_raw="$(make_unsigned_call_tx "$target" "$sig" "$nonce" "$@" 2>/dev/null)"

  mkdir -p "$STEPS_DIR"
  cat <<EOF | tee "$file_path"
{
  "stepIndex": $idx,
  "stepName": "$step_name",
  "kind": "call",
  "contract": "",
  "from": "$DEPLOYER_ADDRESS",
  "nonce": $nonce,
  "chainId": $chain,
  "feeModel": "$fee_model",
  "gasLimit": $gas_limit,
  "gasPrice": "$gas_price",
  "maxFeePerGas": null,
  "maxPriorityFeePerGas": null,
  "to": "$target",
  "value": "0x0",
  "data": "$calldata",
  "unsignedRawTx": "$unsigned_raw",
  "expectedContractAddress": null,
  "assignToVar": "",
  "postCheck": $post_check_json,
  "dependsOn": [],
  "legacy": $legacy_flag,
  "humanSummary": "Call $sig on $target",
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

# --- Shared orchestration (works in both modes) ---

deploy_or_resume() {
  local var_name="$1"
  local contract="$2"
  shift 2

  local current="${!var_name:-}"
  if [[ -n "$current" ]]; then
    if has_code "$current"; then
      echo "using predeployed $var_name at $current" >&2
      return 0
    fi
    echo "provided $var_name address has no code: $current" >&2
    exit 1
  fi

  if [[ "$MODE" == "hot" ]]; then
    local deployed
    if ! deployed="$(deploy_contract_hot "$contract" "$@")"; then
      exit 1
    fi
    printf -v "$var_name" '%s' "$deployed"
    write_manifest
  fi
}

ensure_bool_grant() {
  local target="$1"
  local check_sig="$2"
  local check_arg="$3"
  local grant_sig="$4"
  local grant_arg="$5"
  local current

  current="$(rtk cast call "$target" "$check_sig" "$check_arg" --rpc-url "$RPC_URL")"
  if [[ "$current" == "true" ]]; then
    return 0
  fi

  if [[ "$MODE" == "hot" ]]; then
    send_tx "$target" "$grant_sig" "$grant_arg" true
    wait_for_bool "$target" "$check_sig" "$check_arg" true
  fi
}

transfer_ownership_if_needed() {
  local target="$1"

  if [[ -z "${OWNER_ADDRESS:-}" ]]; then
    return 0
  fi

  if [[ "$OWNER_ADDRESS" == "$DEPLOYER_ADDRESS" ]]; then
    return 0
  fi

  local current_owner
  current_owner="$(rtk cast call "$target" "owner()(address)" --rpc-url "$RPC_URL")"
  if [[ "$current_owner" == "$OWNER_ADDRESS" ]]; then
    return 0
  fi

  if [[ "$current_owner" != "$DEPLOYER_ADDRESS" ]]; then
    echo "cannot transfer ownership for $target; current owner is $current_owner, deployer is $DEPLOYER_ADDRESS" >&2
    exit 1
  fi

  if [[ "$MODE" == "hot" ]]; then
    send_tx "$target" "transferOwnership(address)" "$OWNER_ADDRESS"
    wait_for_owner "$target" "$OWNER_ADDRESS"
  fi
}

# --- Build ---

echo "building delivery workspace..." >&2
rtk forge build

# --- Deployment DAG ---

if [[ "$MODE" == "unsigned" ]]; then
  mkdir -p "$STEPS_DIR"
  init_virtual_nonce
  echo "unsigned mode: preparing step manifests under $STEPS_DIR/" >&2
  echo "sign each step on Keystone, then broadcast with publish-signed.sh" >&2
  echo "" >&2
fi

echo "deploying PurchaseEntitlementToken..." >&2
if [[ "$MODE" == "hot" ]]; then
  deploy_or_resume PURCHASE_ENTITLEMENT_TOKEN src/PurchaseEntitlementToken.sol:PurchaseEntitlementToken
else
  emit_create_step "purchase-entitlement-token" \
    "src/PurchaseEntitlementToken.sol:PurchaseEntitlementToken" \
    "PURCHASE_ENTITLEMENT_TOKEN"
fi

echo "deploying PirateSignerRegistry..." >&2
if [[ "$MODE" == "hot" ]]; then
  deploy_or_resume PIRATE_SIGNER_REGISTRY src/PirateSignerRegistry.sol:PirateSignerRegistry
  ensure_bool_grant \
    "$PIRATE_SIGNER_REGISTRY" \
    "isActiveSigner(address)(bool)" \
    "$ACCESS_PROOF_SIGNER" \
    "setSigner(address,bool)" \
    "$ACCESS_PROOF_SIGNER"
  write_manifest
else
  emit_create_step "pirate-signer-registry" \
    "src/PirateSignerRegistry.sol:PirateSignerRegistry" \
    "PIRATE_SIGNER_REGISTRY"
  emit_call_step "pirate-signer-registry-set-signer" \
    "$PIRATE_SIGNER_REGISTRY" \
    "setSigner(address,bool)" \
    "bool_grant" \
    "$PIRATE_SIGNER_REGISTRY" \
    "isActiveSigner(address)(bool)" \
    "$ACCESS_PROOF_SIGNER" \
    "true" \
    "$ACCESS_PROOF_SIGNER" true
fi

echo "deploying TokenGateCondition..." >&2
if [[ "$MODE" == "hot" ]]; then
  deploy_or_resume TOKEN_GATE_CONDITION src/TokenGateCondition.sol:TokenGateCondition
else
  emit_create_step "token-gate-condition" \
    "src/TokenGateCondition.sol:TokenGateCondition" \
    "TOKEN_GATE_CONDITION"
fi

echo "deploying SignedAccessConditionV1..." >&2
if [[ "$MODE" == "hot" ]]; then
  deploy_or_resume \
    SIGNED_ACCESS_CONDITION_V1 \
    src/SignedAccessConditionV1.sol:SignedAccessConditionV1 \
    --constructor-args "$PIRATE_SIGNER_REGISTRY"
else
  emit_create_step "signed-access-condition-v1" \
    "src/SignedAccessConditionV1.sol:SignedAccessConditionV1" \
    "SIGNED_ACCESS_CONDITION_V1" \
    "constructor(address)" \
    "$PIRATE_SIGNER_REGISTRY"
fi

echo "deploying AssetPublishCoordinatorV1..." >&2
if [[ "$MODE" == "hot" ]]; then
  deploy_or_resume \
    ASSET_PUBLISH_COORDINATOR_V1 \
    src/AssetPublishCoordinatorV1.sol:AssetPublishCoordinatorV1 \
    --constructor-args "$PURCHASE_ENTITLEMENT_TOKEN"
  ensure_bool_grant \
    "$ASSET_PUBLISH_COORDINATOR_V1" \
    "isPublishOperator(address)(bool)" \
    "$PUBLISH_OPERATOR" \
    "setPublishOperator(address,bool)" \
    "$PUBLISH_OPERATOR"
  write_manifest
else
  emit_create_step "asset-publish-coordinator-v1" \
    "src/AssetPublishCoordinatorV1.sol:AssetPublishCoordinatorV1" \
    "ASSET_PUBLISH_COORDINATOR_V1" \
    "constructor(address)" \
    "$PURCHASE_ENTITLEMENT_TOKEN"
  emit_call_step "asset-publish-coordinator-v1-set-publish-operator" \
    "$ASSET_PUBLISH_COORDINATOR_V1" \
    "setPublishOperator(address,bool)" \
    "bool_grant" \
    "$ASSET_PUBLISH_COORDINATOR_V1" \
    "isPublishOperator(address)(bool)" \
    "$PUBLISH_OPERATOR" \
    "true" \
    "$PUBLISH_OPERATOR" true
fi

echo "deploying MarketplaceSettlementV1..." >&2
if [[ "$MODE" == "hot" ]]; then
  deploy_or_resume \
    MARKETPLACE_SETTLEMENT_V1 \
    src/MarketplaceSettlementV1.sol:MarketplaceSettlementV1 \
    --constructor-args "$PURCHASE_ENTITLEMENT_TOKEN"
  ensure_bool_grant \
    "$MARKETPLACE_SETTLEMENT_V1" \
    "isSettlementOperator(address)(bool)" \
    "$SETTLEMENT_OPERATOR" \
    "setSettlementOperator(address,bool)" \
    "$SETTLEMENT_OPERATOR"
  ensure_bool_grant \
    "$PURCHASE_ENTITLEMENT_TOKEN" \
    "isSettlementMinter(address)(bool)" \
    "$MARKETPLACE_SETTLEMENT_V1" \
    "setSettlementMinter(address,bool)" \
    "$MARKETPLACE_SETTLEMENT_V1"
  write_manifest
else
  emit_create_step "marketplace-settlement-v1" \
    "src/MarketplaceSettlementV1.sol:MarketplaceSettlementV1" \
    "MARKETPLACE_SETTLEMENT_V1" \
    "constructor(address)" \
    "$PURCHASE_ENTITLEMENT_TOKEN"
  emit_call_step "marketplace-settlement-v1-set-settlement-operator" \
    "$MARKETPLACE_SETTLEMENT_V1" \
    "setSettlementOperator(address,bool)" \
    "bool_grant" \
    "$MARKETPLACE_SETTLEMENT_V1" \
    "isSettlementOperator(address)(bool)" \
    "$SETTLEMENT_OPERATOR" \
    "true" \
    "$SETTLEMENT_OPERATOR" true
  emit_call_step "purchase-entitlement-token-set-settlement-minter" \
    "$PURCHASE_ENTITLEMENT_TOKEN" \
    "setSettlementMinter(address,bool)" \
    "bool_grant" \
    "$PURCHASE_ENTITLEMENT_TOKEN" \
    "isSettlementMinter(address)(bool)" \
    "$MARKETPLACE_SETTLEMENT_V1" \
    "true" \
    "$MARKETPLACE_SETTLEMENT_V1" true
fi

if [[ -n "${OWNER_ADDRESS:-}" ]]; then
  echo "ensuring final ownership..." >&2
  if [[ "$MODE" == "hot" ]]; then
    transfer_ownership_if_needed "$PURCHASE_ENTITLEMENT_TOKEN"
    transfer_ownership_if_needed "$PIRATE_SIGNER_REGISTRY"
    transfer_ownership_if_needed "$ASSET_PUBLISH_COORDINATOR_V1"
    transfer_ownership_if_needed "$MARKETPLACE_SETTLEMENT_V1"
  else
    emit_call_step "purchase-entitlement-token-transfer-ownership" \
      "$PURCHASE_ENTITLEMENT_TOKEN" \
      "transferOwnership(address)" \
      "owner_transfer" \
      "$OWNER_ADDRESS"
    emit_call_step "pirate-signer-registry-transfer-ownership" \
      "$PIRATE_SIGNER_REGISTRY" \
      "transferOwnership(address)" \
      "owner_transfer" \
      "$OWNER_ADDRESS"
    emit_call_step "asset-publish-coordinator-v1-transfer-ownership" \
      "$ASSET_PUBLISH_COORDINATOR_V1" \
      "transferOwnership(address)" \
      "owner_transfer" \
      "$OWNER_ADDRESS"
    emit_call_step "marketplace-settlement-v1-transfer-ownership" \
      "$MARKETPLACE_SETTLEMENT_V1" \
      "transferOwnership(address)" \
      "owner_transfer" \
      "$OWNER_ADDRESS"
  fi
else
  echo "warning: OWNER_ADDRESS not set; deployer retains ownership of all ownable delivery contracts" >&2
fi

if [[ "$MODE" == "hot" ]]; then
  DELIVERY_DEPLOYMENT_COMPLETE=1
  write_manifest
  cat "$MANIFEST_PATH"
else
  echo "" >&2
  echo "unsigned mode complete. step manifests written to:" >&2
  echo "  $STEPS_DIR/" >&2
  echo "" >&2
  echo "next steps:" >&2
  echo "  1. for each step JSON, sign the unsignedRawTx on Keystone" >&2
  echo "  2. save the signed raw tx to a file" >&2
  echo "  3. broadcast with: publish-signed.sh --step <step-json> --signed-tx-file <file>" >&2
  echo "  4. repeat for the next step" >&2
  echo "" >&2
  echo "important: steps must be broadcast in order. nonce values were assigned" >&2
  echo "sequentially at prepare time. if any step fails, regenerate from that step." >&2
  cat "$MANIFEST_PATH"
fi
