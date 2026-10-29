#!/usr/bin/env bash
# Verifies the launcher, treasury and rack on Robinscan (Etherscan API V2), or on Blockscout if ETHERSCAN_API_KEY is
# unset. The treasury and rack are deployed by the launcher's constructor, so they are verified here with constructor
# arguments read from the chain.
#
# Needs Foundry 1.x (Etherscan API V2; `foundryup`): older versions ignore the API key on chain 4663. The Etherscan URL
# is explicit: Foundry's built-in one for this chain is Blockscout's.
#
# Each contract is tried even if another fails; the script exits non-zero if any did.
#
# Usage: script/verify.sh <launcher address>
# Environment (from .env): RPC_URL (default: the public Robinhood Chain RPC), ETHERSCAN_API_KEY.
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

LAUNCHER=${1:?usage: script/verify.sh <launcher address>}
RPC_URL=${RPC_URL:-https://rpc.mainnet.chain.robinhood.com}
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
  VERIFIER=(--verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=$CHAIN_ID"
    --etherscan-api-key "$ETHERSCAN_API_KEY")
else
  VERIFIER=(--verifier blockscout --verifier-url "https://robinhoodchain.blockscout.com/api/")
fi

TREASURY=$(cast call "$LAUNCHER" "treasury()(address)" --rpc-url "$RPC_URL")
RACK=$(cast call "$TREASURY" "rack()(address)" --rpc-url "$RPC_URL")
RECLAMM_FACTORY=$(cast call "$LAUNCHER" "reClammFactory()(address)" --rpc-url "$RPC_URL")
WEIGHTED_FACTORY=$(cast call "$LAUNCHER" "weightedFactory()(address)" --rpc-url "$RPC_URL")
VAULT=$(cast call "$LAUNCHER" "vault()(address)" --rpc-url "$RPC_URL")
CURATOR=$(cast call "$TREASURY" "curator()(address)" --rpc-url "$RPC_URL")

echo "Launcher $LAUNCHER, treasury $TREASURY, rack $RACK (chain $CHAIN_ID)"

FAILED=()
verify() {
  forge verify-contract "$1" "$2" \
    --chain-id "$CHAIN_ID" \
    "${VERIFIER[@]}" \
    ${3:+--constructor-args "$3"} \
    --watch || FAILED+=("$2 at $1")
}

verify "$LAUNCHER" contracts/staking-rewards/StakingRewardsLauncher.sol:StakingRewardsLauncher \
  "$(cast abi-encode "constructor(address,address,address)" "$RECLAMM_FACTORY" "$WEIGHTED_FACTORY" "$CURATOR")"
verify "$TREASURY" contracts/staking-rewards/StakingRewardsTreasury.sol:StakingRewardsTreasury \
  "$(cast abi-encode "constructor(address,address)" "$VAULT" "$CURATOR")"
verify "$RACK" contracts/staking-rewards/StakingRewardsRack.sol:StakingRewardsRack

if (( ${#FAILED[@]} )); then
  printf 'Not verified: %s\n' "${FAILED[@]}"
  exit 1
fi
echo "All verified."
