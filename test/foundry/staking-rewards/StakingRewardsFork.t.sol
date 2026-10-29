// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";

import { IProtocolFeeController } from "@bush.fi/v3-interfaces/contracts/vault/IProtocolFeeController.sol";
import { IRouter } from "@bush.fi/v3-interfaces/contracts/vault/IRouter.sol";
import { IVault } from "@bush.fi/v3-interfaces/contracts/vault/IVault.sol";
import { IRateProvider } from "@bush.fi/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { PoolRoleAccounts, TokenConfig, TokenType } from "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { InputHelpers } from "@bush.fi/v3-solidity-utils/contracts/helpers/InputHelpers.sol";

import { WeightedPoolFactory } from "../../../contracts/weighted/WeightedPoolFactory.sol";
import { ReClammPoolFactory } from "../../../contracts/reclamm/ReClammPoolFactory.sol";
import { ReClammPoolHelper } from "../../../contracts/reclamm/ReClammPoolHelper.sol";
import { IReClammPool } from "../../../contracts/reclamm/interfaces/IReClammPool.sol";
import {
    StakingRewardsLauncher,
    StakingRewardsParams,
    StakingRewardsReClammParams
} from "../../../contracts/staking-rewards/StakingRewardsLauncher.sol";
import { StakingRewardsTreasury } from "../../../contracts/staking-rewards/StakingRewardsTreasury.sol";

interface IRouterWithPermit2 {
    function getPermit2() external view returns (IPermit2);
}

/**
 * @notice The creator fee path against the live Robinhood Chain Vault, Router, fee controller (and its real protocol
 * fee), WIF and WETH: the launcher creates a stock ReClamm pool, the treasury sets its creator fee at once,
 * initialization keeps it, and the treasury then collects its share of every trade.
 *
 * Skipped unless FORK_URL is set: `FORK_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract
 * StakingRewardsForkTest`.
 */
contract StakingRewardsForkTest is Test {
    IVault internal constant VAULT = IVault(0xB055000fbE3cc9bDE7742C583a86cc6283E3fF85);
    IRouter internal constant ROUTER = IRouter(0xa93179c0cd90B9D1569Cf20FD403a9A67540Ea4d);
    IERC20 internal constant WETH = IERC20(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
    IERC20 internal constant WIF = IERC20(0x5173b8eA6923c2d40267890D45C46a3480954773);

    uint256 internal constant CREATOR_FEE = 50e16;

    IProtocolFeeController internal feeController;
    StakingRewardsLauncher internal launcher;
    StakingRewardsTreasury internal treasury;
    address internal indexPool;

    function setUp() public {
        string memory forkUrl = vm.envOr("FORK_URL", string(""));
        if (bytes(forkUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(forkUrl);

        feeController = VAULT.getProtocolFeeController();
        deal(address(WIF), address(this), 10_000_000e18);
        deal(address(WETH), address(this), 1_000e18);
        IPermit2 permit2 = IRouterWithPermit2(address(ROUTER)).getPermit2();
        IERC20[2] memory tokens = [WIF, WETH];
        for (uint256 i = 0; i < 2; ++i) {
            tokens[i].approve(address(permit2), type(uint256).max);
            permit2.approve(address(tokens[i]), address(ROUTER), type(uint160).max, type(uint48).max);
        }

        WeightedPoolFactory weightedFactory = new WeightedPoolFactory(VAULT, 365 days, "", "");
        ReClammPoolFactory reClammFactory = new ReClammPoolFactory(VAULT, new ReClammPoolHelper(VAULT), 365 days, "", "");
        launcher = new StakingRewardsLauncher(reClammFactory, weightedFactory, WIF, address(this));
        treasury = launcher.treasury();

        // A bare 50/50 WIF/WETH index.
        IERC20[] memory indexTokens = new IERC20[](2);
        (indexTokens[0], indexTokens[1]) = (WIF, WETH);
        indexTokens = InputHelpers.sortTokens(indexTokens);
        uint256[] memory weights = new uint256[](2);
        (weights[0], weights[1]) = (50e16, 50e16);
        TokenConfig[] memory tokenConfig = new TokenConfig[](2);
        for (uint256 i = 0; i < 2; ++i) {
            tokenConfig[i] = TokenConfig(indexTokens[i], TokenType.STANDARD, IRateProvider(address(0)), false);
        }
        PoolRoleAccounts memory roles;
        indexPool = weightedFactory.create(
            "Index",
            "IDX",
            tokenConfig,
            weights,
            roles,
            1e16,
            address(0),
            false,
            false,
            bytes32(0)
        );
        treasury.allowIndexPool(indexPool);
        uint256[] memory indexAmounts = new uint256[](2);
        (indexAmounts[0], indexAmounts[1]) = indexTokens[0] == WIF
            ? (uint256(1_000_000e18), uint256(10e18))
            : (uint256(10e18), uint256(1_000_000e18));
        ROUTER.initialize(indexPool, indexTokens, indexAmounts, 0, false, "");
    }

    function testCreatorFeeSetAtLaunchAndPays() public {
        address pool = launcher.createReClammPool(
            StakingRewardsParams({
                name: "WIF Staking Rewards",
                symbol: "WIF-SRP",
                swapFeePercentage: 1e16,
                creatorFeePercentage: CREATOR_FEE,
                stakerShare: 50e16
            }),
            StakingRewardsReClammParams({
                baseToken: WIF,
                quoteToken: WETH,
                initialMinPrice: 0.000004e18,
                initialMaxPrice: 0.00002e18,
                initialTargetPrice: 0.00001e18,
                dailyPriceShiftExponent: 10e16,
                centerednessMargin: 20e16
            }),
            indexPool,
            bytes32(0)
        );

        // The creator fee is set at launch.
        (uint256 protocolFee, ) = feeController.getPoolProtocolSwapFeeInfo(pool);
        uint256 expectedAggregate = feeController.computeAggregateFeePercentage(protocolFee, CREATOR_FEE);
        assertEq(feeController.getPoolCreatorSwapFeePercentage(pool), CREATOR_FEE, "creator fee not set at launch");
        assertEq(VAULT.getPoolConfig(pool).aggregateSwapFeePercentage, expectedAggregate, "Vault: aggregate not set");

        // Initializing keeps it.
        IERC20[] memory tokens = VAULT.getPoolTokens(pool);
        ROUTER.initialize(pool, tokens, IReClammPool(pool).computeInitialBalancesRaw(WIF, 1_000_000e18), 0, false, "");
        assertTrue(VAULT.isPoolInitialized(pool), "not initialized");
        assertEq(feeController.getPoolCreatorSwapFeePercentage(pool), CREATOR_FEE, "controller: creator fee lost");
        assertEq(VAULT.getPoolConfig(pool).aggregateSwapFeePercentage, expectedAggregate, "Vault: aggregate reset");

        // A sell and a buy pay the treasury its share.
        ROUTER.swapSingleTokenExactIn(pool, WIF, WETH, 50_000e18, 0, type(uint256).max, false, "");
        ROUTER.swapSingleTokenExactIn(pool, WETH, WIF, 0.5e18, 0, type(uint256).max, false, "");

        vm.recordLogs();
        treasury.harvest(pool);
        (uint256 fees0, uint256 fees1) = _harvestedFees();
        (uint256 wifIdx, uint256 wethIdx) = tokens[0] == WIF ? (0, 1) : (1, 0);
        uint256[2] memory fees = [fees0, fees1];

        // 50,000 WIF at 1%, of which the treasury gets the creator share of what's left after the protocol fee.
        uint256 expectedWif = (((50_000e18 * 1e16) / 1e18) * (1e18 - protocolFee) * CREATOR_FEE) / 1e36;
        assertApproxEqRel(fees[wifIdx], expectedWif, 1e15, "treasury WIF fees");
        assertGt(fees[wethIdx], 0, "no WETH fees");
        assertGt(treasury.protocolOwnedBpt(pool), 0, "no POL");
        emit log_named_uint("live protocol swap fee", protocolFee);
        emit log_named_uint("treasury WIF fees", fees[wifIdx]);
        emit log_named_uint("treasury WETH fees", fees[wethIdx]);
    }

    function _harvestedFees() internal returns (uint256 fees0, uint256 fees1) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(treasury) && logs[i].topics[0] == StakingRewardsTreasury.Harvested.selector) {
                (uint256[] memory fees, , , , ) = abi.decode(
                    logs[i].data,
                    (uint256[], uint256[], uint256, uint256[], uint256)
                );
                return (fees[0], fees[1]);
            }
        }
        revert("no Harvested event");
    }
}
