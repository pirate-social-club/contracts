#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DEPLOY_TAG="${DEPLOY_TAG:-manual}"
FORCE_REDEPLOY="${FORCE_REDEPLOY:-0}"
LEGACY="${LEGACY:-0}"
DEPLOYMENTS_DIR="$ROOT_DIR/deployments"
MANIFEST_PATH="$DEPLOYMENTS_DIR/$DEPLOY_TAG.env"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "missing required env: $name" >&2
    exit 1
  fi
}

require_env RPC_URL
require_env STORY_CONTRACT_OWNER_PRIVATE_KEY
require_env PUBLISH_OPERATOR
require_env SETTLEMENT_OPERATOR
require_env ACCESS_PROOF_SIGNER

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

DEPLOYER_ADDRESS="$(rtk cast wallet address --private-key "$STORY_CONTRACT_OWNER_PRIVATE_KEY")"

write_manifest() {
  cat <<EOF >"$MANIFEST_PATH"
DELIVERY_DEPLOYMENT_COMPLETE=${DELIVERY_DEPLOYMENT_COMPLETE:-0}
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

deploy_contract() {
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

  local deployed
  if ! deployed="$(deploy_contract "$contract" "$@")"; then
    exit 1
  fi
  printf -v "$var_name" '%s' "$deployed"
  write_manifest
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

  send_tx "$target" "$grant_sig" "$grant_arg" true
  wait_for_bool "$target" "$check_sig" "$check_arg" true
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

  send_tx "$target" "transferOwnership(address)" "$OWNER_ADDRESS"
  wait_for_owner "$target" "$OWNER_ADDRESS"
}

echo "building delivery workspace..." >&2
rtk forge build

echo "deploying PurchaseEntitlementToken..." >&2
deploy_or_resume PURCHASE_ENTITLEMENT_TOKEN src/PurchaseEntitlementToken.sol:PurchaseEntitlementToken

echo "deploying PirateSignerRegistry..." >&2
deploy_or_resume PIRATE_SIGNER_REGISTRY src/PirateSignerRegistry.sol:PirateSignerRegistry
ensure_bool_grant \
  "$PIRATE_SIGNER_REGISTRY" \
  "isActiveSigner(address)(bool)" \
  "$ACCESS_PROOF_SIGNER" \
  "setSigner(address,bool)" \
  "$ACCESS_PROOF_SIGNER"
write_manifest

echo "deploying TokenGateCondition..." >&2
deploy_or_resume TOKEN_GATE_CONDITION src/TokenGateCondition.sol:TokenGateCondition

echo "deploying SignedAccessConditionV1..." >&2
deploy_or_resume \
  SIGNED_ACCESS_CONDITION_V1 \
  src/SignedAccessConditionV1.sol:SignedAccessConditionV1 \
  --constructor-args "$PIRATE_SIGNER_REGISTRY"

echo "deploying AssetPublishCoordinatorV1..." >&2
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

echo "deploying MarketplaceSettlementV1..." >&2
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

if [[ -n "${OWNER_ADDRESS:-}" ]]; then
  echo "ensuring final ownership..." >&2
  transfer_ownership_if_needed "$PURCHASE_ENTITLEMENT_TOKEN"
  transfer_ownership_if_needed "$PIRATE_SIGNER_REGISTRY"
  transfer_ownership_if_needed "$ASSET_PUBLISH_COORDINATOR_V1"
  transfer_ownership_if_needed "$MARKETPLACE_SETTLEMENT_V1"
else
  echo "warning: OWNER_ADDRESS not set; deployer retains ownership of all ownable delivery contracts" >&2
fi

DELIVERY_DEPLOYMENT_COMPLETE=1
write_manifest
cat "$MANIFEST_PATH"
