// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IVault } from "@bush.fi/v3-interfaces/contracts/vault/IVault.sol";

import { ReClammPoolFactory } from "../contracts/reclamm/ReClammPoolFactory.sol";
import { WeightedPoolFactory } from "../contracts/weighted/WeightedPoolFactory.sol";
import { StakingRewardsLauncher } from "../contracts/staking-rewards/StakingRewardsLauncher.sol";
import { StakingRewardsTreasury } from "../contracts/staking-rewards/StakingRewardsTreasury.sol";

/**
 * @notice Deploys the launcher, which deploys the treasury and the rack. The curator sets the staking token afterwards
 * (`treasury.setStakingToken`), then approves index pools.
 * @dev Environment (from `.env`): `RECLAMM_FACTORY`, `WEIGHTED_FACTORY` (the deployed Bush factories), `CURATOR` (use
 * a multisig) and `PRIVATE_KEY` (the deployer; leave it empty to sign with `--account` instead). On Robinhood Chain, the
 * factories must use the live Vault.
 *
 * Dry run: `forge script script/DeployStakingRewards.s.sol --rpc-url $RPC_URL`; add `--broadcast` to deploy, then
 * `script/verify.sh <launcher>`.
 */
contract DeployStakingRewards is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    IVault internal constant ROBINHOOD_VAULT = IVault(0xB055000fbE3cc9bDE7742C583a86cc6283E3fF85);

    function run() external returns (StakingRewardsLauncher launcher) {
        ReClammPoolFactory reClammFactory = ReClammPoolFactory(vm.envAddress("RECLAMM_FACTORY"));
        WeightedPoolFactory weightedFactory = WeightedPoolFactory(vm.envAddress("WEIGHTED_FACTORY"));
        address curator = vm.envAddress("CURATOR");

        require(address(reClammFactory).code.length > 0, "RECLAMM_FACTORY has no code");
        require(address(weightedFactory).code.length > 0, "WEIGHTED_FACTORY has no code");
        require(curator != address(0), "CURATOR is zero");
        if (block.chainid == ROBINHOOD_CHAIN_ID) {
            require(reClammFactory.getVault() == ROBINHOOD_VAULT, "ReClamm factory is not on the live Vault");
        }
        // The launcher checks that the weighted factory uses the same Vault (`WrongFactoryVault`).

        // A string, so an empty `PRIVATE_KEY=` in `.env` means "not set".
        string memory privateKey = vm.envOr("PRIVATE_KEY", string(""));
        if (bytes(privateKey).length > 0) {
            vm.startBroadcast(vm.parseUint(privateKey));
        } else {
            vm.startBroadcast();
        }
        launcher = new StakingRewardsLauncher(reClammFactory, weightedFactory, curator);
        vm.stopBroadcast();

        StakingRewardsTreasury treasury = launcher.treasury();
        console2.log("Vault           ", address(launcher.vault()));
        console2.log("Launcher        ", address(launcher));
        console2.log("Treasury        ", address(treasury));
        console2.log("Rack            ", address(treasury.rack()));
        console2.log("Curator         ", curator);
        console2.log("Next: the curator calls treasury.setStakingToken(token), then allowIndexPool(index).");
    }
}
