// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Vm } from "forge-std/Vm.sol";

import { IVaultErrors } from "@bush.fi/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IWeightedPool } from "@bush.fi/v3-interfaces/contracts/pool-weighted/IWeightedPool.sol";
import { IVault } from "@bush.fi/v3-interfaces/contracts/vault/IVault.sol";
import { HooksConfig, PoolRoleAccounts, TokenConfig } from "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { InputHelpers } from "@bush.fi/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { IReClammPool } from "../../../contracts/reclamm/interfaces/IReClammPool.sol";
import { WeightedPool } from "../../../contracts/weighted/WeightedPool.sol";
import { WeightedPoolFactory } from "../../../contracts/weighted/WeightedPoolFactory.sol";
import {
    StakingRewardsLauncher,
    StakingRewardsParams,
    StakingRewardsReClammParams
} from "../../../contracts/staking-rewards/StakingRewardsLauncher.sol";
import { StakingRewardsTreasury } from "../../../contracts/staking-rewards/StakingRewardsTreasury.sol";
import { StakingRewardsRack } from "../../../contracts/staking-rewards/StakingRewardsRack.sol";
import { BaseStakingRewardsTest } from "../utils/BaseStakingRewardsTest.sol";

/**
 * @notice Unit tests of the staking rewards launcher, treasury and rack (setup: `BaseStakingRewardsTest`).
 * Every test runs twice (the contracts at the bottom): with a 0% and a 20% protocol swap fee.
 */
abstract contract StakingRewardsTest is BaseStakingRewardsTest {
    using FixedPoint for uint256;

    /***************************************************************************
                                    Wiring
    ***************************************************************************/

    function testPoolWiring() public view {
        HooksConfig memory hooks = vault.getHooksConfig(pool);
        assertEq(hooks.hooksContract, pool, "pool is not its own hook");
        assertFalse(hooks.shouldCallComputeDynamicSwapFee, "dynamic fee");
        assertTrue(hooks.shouldCallBeforeInitialize, "ReClamm before-initialize hook lost");
        assertFalse(hooks.shouldCallAfterInitialize, "not a stock ReClamm pool");

        address[2] memory pools = [pool, poolB];
        for (uint256 i = 0; i < 2; ++i) {
            assertTrue(reClammFactory.isPoolFromFactory(pools[i]), "not a ReClamm factory pool");
            _assertStakingRewardsRoles(pools[i]);
            IERC20[] memory configTokens = treasury.getPoolConfig(pools[i]).tokens;
            IERC20[] memory vaultTokens = vault.getPoolTokens(pools[i]);
            assertEq(configTokens.length, 2, "token count");
            assertEq(address(configTokens[0]), address(vaultTokens[0]), "token 0");
            assertEq(address(configTokens[1]), address(vaultTokens[1]), "token 1");
            assertFalse(treasury.isSelfRewarding(pools[i]), "ReClamm pool self-rewarding");
        }

        assertEq(treasury.getPoolConfig(pool).indexPool, indexA, "pool A index");
        assertEq(treasury.getPoolConfig(poolB).indexPool, indexB, "pool B index");
        assertEq(treasury.launcher(), address(launcher), "treasury launcher");
        assertEq(treasury.curator(), admin, "curator");
        assertEq(launcher.rack(), address(rack), "launcher rack");
        assertEq(address(launcher.vault()), address(vault), "launcher vault");
        assertEq(rack.treasury(), address(treasury), "rack treasury mismatch");
        assertEq(address(rack.stakingToken()), address(wif), "rack stakes the wrong token");

        IERC20[] memory rewardTokens = rack.getRewardTokens();
        assertEq(rewardTokens.length, 2, "reward token count");
        assertEq(address(rewardTokens[0]), indexA, "reward token A");
        assertEq(address(rewardTokens[1]), indexB, "reward token B");
    }

    function testLauncherRejectsFactoriesOfAnotherVault() public {
        WeightedPoolFactory otherWeighted = new WeightedPoolFactory(
            IVault(address(0xdead)),
            365 days,
            "",
            ""
        );
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsLauncher.WrongFactoryVault.selector, address(otherWeighted)));
        new StakingRewardsLauncher(reClammFactory, otherWeighted, wif, admin);
    }

    function testRegisterOnlyLauncherAndOnce() public {
        vm.expectRevert(StakingRewardsTreasury.SenderIsNotLauncher.selector);
        treasury.registerPool(pool, indexA, 0, 0);

        vm.prank(address(launcher));
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsTreasury.AlreadyRegistered.selector, pool));
        treasury.registerPool(pool, indexA, 0, 0);
    }

    /// @dev The creator fee is set at launch, before initialization, and `initialize` keeps it.
    function testCreatorFeeSetAtLaunchAndKeptOnInitialize() public {
        address newPool = _launchReClamm(_defaultParams());

        (uint256 protocolFee, ) = feeController.getPoolProtocolSwapFeeInfo(newPool);
        uint256 expectedAggregate = feeController.computeAggregateFeePercentage(protocolFee, CREATOR_FEE);
        assertEq(feeController.getPoolCreatorSwapFeePercentage(newPool), CREATOR_FEE, "creator fee not set at launch");
        assertEq(vault.getPoolConfig(newPool).aggregateSwapFeePercentage, expectedAggregate, "aggregate not set");

        // Nothing to harvest until it is initialized.
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsTreasury.PoolNotInitialized.selector, newPool));
        treasury.harvest(newPool);

        vm.startPrank(lp);
        _initPool(newPool, IReClammPool(newPool).computeInitialBalancesRaw(wif, SEED), 0);
        vm.stopPrank();

        assertEq(feeController.getPoolCreatorSwapFeePercentage(newPool), CREATOR_FEE, "creator fee lost");
        assertEq(vault.getPoolConfig(newPool).aggregateSwapFeePercentage, expectedAggregate, "aggregate reset");
    }

    function testLauncherRejectsBadParams() public {
        LaunchParams memory params = _defaultParams();
        params.quoteToken = wif;
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsLauncher.DuplicateToken.selector, wif));
        _launchReClamm(params);

        // The Vault enforces ReClamm's swap fee bounds (0.001% to 10%).
        params = _defaultParams();
        params.swapFeePercentage = 0.0001e16;
        vm.expectRevert(IVaultErrors.SwapFeePercentageTooLow.selector);
        _launchReClamm(params);

        params = _defaultParams();
        params.swapFeePercentage = 10.01e16;
        vm.expectRevert(IVaultErrors.SwapFeePercentageTooHigh.selector);
        _launchReClamm(params);

        params = _defaultParams();
        params.creatorFeePercentage = 90.01e16;
        vm.expectRevert(StakingRewardsLauncher.CreatorFeeTooHigh.selector);
        _launchReClamm(params);

        params = _defaultParams();
        params.stakerShare = 100.01e16;
        vm.expectRevert(StakingRewardsLauncher.StakerShareTooHigh.selector);
        _launchReClamm(params);

        // The same checks guard weighted launches.
        params = _defaultParams();
        params.creatorFeePercentage = 90.01e16;
        vm.expectRevert(StakingRewardsLauncher.CreatorFeeTooHigh.selector);
        _launchWeighted(params, 50e16);
    }

    function testLauncherRejectsBadWeights() public {
        // Over 100%: the quote weight underflows.
        vm.expectRevert();
        _launchWeighted(_defaultParams(), 100.01e16);

        // Under the weighted pool's 1% minimum, on either side.
        vm.expectRevert(IWeightedPool.MinWeight.selector);
        _launchWeighted(_defaultParams(), 0.5e16);
        vm.expectRevert(IWeightedPool.MinWeight.selector);
        _launchWeighted(_defaultParams(), 99.5e16);
    }

    function testLauncherRejectsUnapprovedIndex() public {
        address unapproved = _createIndexA(true);
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsTreasury.IndexPoolNotAllowed.selector, unapproved));
        _launchReClamm(_params(wif, unapproved));

        vm.expectRevert(abi.encodeWithSelector(StakingRewardsTreasury.IndexPoolNotAllowed.selector, unapproved));
        _launchWeighted(_params(wif, unapproved), 50e16);
    }

    function testLauncherRejectsPairNotInIndex() public {
        // Index B holds USDC and WETH, but not WIF: a WIF/WETH pool can't use it.
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsTreasury.IndexPoolMissingToken.selector, wif));
        _launchReClamm(_params(wif, indexB));

        // An approved index without WETH can't take a WIF/WETH pool either.
        address noWeth = _createIndexA(false);
        vm.prank(admin);
        treasury.allowIndexPool(noWeth);
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsTreasury.IndexPoolMissingToken.selector, pair));
        _launchWeighted(_params(wif, noWeth), 50e16);
    }

    function testLauncherInvertsPricesWhenBaseTokenSortsSecond() public {
        // Whichever side `dai` sorts on, a new pool with base and quote swapped must price the tokens the same.
        LaunchParams memory params = _defaultParams();
        params.baseToken = pair;
        params.quoteToken = wif;
        StakingRewardsReClammParams memory reClammParams = _reClammParams(params);
        reClammParams.initialMinPrice = 2e18; // 1 / 0.5
        reClammParams.initialMaxPrice = 10e18; // 1 / 0.1
        reClammParams.initialTargetPrice = 4e18; // 1 / 0.25
        address otherPool = launcher.createReClammPool(
            _stakingRewardsParams(params),
            reClammParams,
            indexA,
            bytes32(_salt++)
        );

        uint256[] memory a = IReClammPool(pool).computeInitialBalancesRaw(wif, SEED);
        uint256[] memory b = IReClammPool(otherPool).computeInitialBalancesRaw(wif, SEED);
        assertApproxEqRel(a[pairIdx], b[pairIdx], 1e6, "the inverted range prices differently");
    }

    function testSaltKeyedByCaller() public {
        bytes32 salt = keccak256("same salt");
        StakingRewardsParams memory params = _stakingRewardsParams(_defaultParams());
        StakingRewardsReClammParams memory reClammParams = _reClammParams(_defaultParams());
        vm.prank(alice);
        address first = launcher.createReClammPool(params, reClammParams, indexA, salt);

        // Another caller with the same salt gets another address, so nobody can take a pool's address first.
        vm.prank(bob);
        address second = launcher.createReClammPool(params, reClammParams, indexA, salt);
        assertNotEq(first, second, "callers share salts");

        // The same caller can't reuse one.
        vm.prank(alice);
        vm.expectRevert();
        launcher.createReClammPool(params, reClammParams, indexA, salt);
    }

    /***************************************************************************
                                Weighted pools
    ***************************************************************************/

    /// @dev A weighted staking rewards pool (WIF 80%) runs the same loop: creator fee, index rewards and POL.
    function testWeightedPoolStakingRewards() public {
        address weighted = _launchWeighted(_defaultParams(), 80e16);

        assertTrue(weightedFactory.isPoolFromFactory(weighted), "not a weighted factory pool");
        assertEq(vault.getHooksConfig(weighted).hooksContract, address(0), "weighted pool has a hook");
        _assertStakingRewardsRoles(weighted);
        uint256[] memory weights = WeightedPool(weighted).getNormalizedWeights();
        assertEq(weights[wifIdx], 80e16, "base weight");
        assertEq(weights[pairIdx], 20e16, "quote weight");

        // 80,000 WIF at 0.25 WETH is 20,000 WETH of value: 80%, so 5,000 WETH is the other 20%.
        vm.startPrank(lp);
        _initPool(weighted, _amounts(SEED, 5_000e18), 0);
        vm.stopPrank();
        assertEq(feeController.getPoolCreatorSwapFeePercentage(weighted), CREATOR_FEE, "creator fee lost");

        _stake(alice, 1_000e18);
        _trade(weighted, wif, 2_000e18);
        Harvest memory h = _harvest(weighted);

        assertGt(h.fees[wifIdx], 0, "no WIF fees");
        assertGt(h.fees[pairIdx], 0, "no WETH fees");
        assertGt(h.indexBptStreamed, 0, "nothing streamed");
        assertGt(h.polBpt, 0, "no POL");
        assertEq(treasury.protocolOwnedBpt(weighted), h.polBpt, "POL not held");

        // Pools A and B have not traded, so the treasury holds only the weighted pool's leftovers.
        StakingRewardsTreasury.Ledger memory ledger = treasury.getLedger(weighted);
        uint256[2] memory booked = [ledger.reserved[0] + ledger.carry[0], ledger.reserved[1] + ledger.carry[1]];
        assertEq(wif.balanceOf(address(treasury)), booked[wifIdx], "treasury WIF != ledger");
        assertEq(pair.balanceOf(address(treasury)), booked[pairIdx], "treasury WETH != ledger");
    }

    function testWeightedLauncherRejectsBadTokens() public {
        StakingRewardsParams memory params = _stakingRewardsParams(_defaultParams());

        vm.expectRevert(abi.encodeWithSelector(StakingRewardsLauncher.DuplicateToken.selector, wif));
        launcher.createWeightedPool(
            params,
            _weightedParams(_tokens3(wif, pair, wif), _weights3(40e16, 30e16, 30e16)),
            indexA,
            bytes32(_salt++)
        );

        vm.expectRevert(InputHelpers.InputLengthMismatch.selector);
        launcher.createWeightedPool(
            params,
            _weightedParams(_tokens3(wif, pair, usdc), new uint256[](2)),
            indexA,
            bytes32(_salt++)
        );

        // Index B holds USDC and WETH, but not WIF.
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsTreasury.IndexPoolMissingToken.selector, wif));
        launcher.createWeightedPool(
            params,
            _weightedParams(_tokens3(usdc, pair, wif), _weights3(40e16, 30e16, 30e16)),
            indexB,
            bytes32(_salt++)
        );
    }

    /// @dev A three-token weighted pool (given unsorted) feeds index A, which holds all three: each fee token goes in.
    function testThreeTokenWeightedPoolFeedsIndex() public {
        IERC20[] memory list = _tokens3(usdt, wif, pair);
        address weighted = launcher.createWeightedPool(
            _stakingRewardsParams(_defaultParams()),
            _weightedParams(list, _weights3(20e16, 50e16, 30e16)),
            indexA,
            bytes32(_salt++)
        );
        _assertStakingRewardsRoles(weighted);

        IERC20[] memory poolTokens = vault.getPoolTokens(weighted);
        uint256[] memory weights = WeightedPool(weighted).getNormalizedWeights();
        assertEq(treasury.getPoolConfig(weighted).tokens.length, 3, "treasury token count");
        for (uint256 i = 0; i < 3; ++i) {
            uint256 expected = poolTokens[i] == usdt ? 20e16 : poolTokens[i] == wif ? 50e16 : 30e16;
            assertEq(weights[i], expected, "weight sorted with the wrong token");
        }

        _initWeighted(weighted, list, _amounts3(12_000e18, 80_000e18, 3_600e18));
        _stake(alice, 1_000e18);

        // Every token sold in, so every token collects fees.
        vm.startPrank(bob);
        router.swapSingleTokenExactIn(weighted, wif, usdt, 2_000e18, 0, type(uint256).max, false, "");
        router.swapSingleTokenExactIn(weighted, usdt, pair, 300e18, 0, type(uint256).max, false, "");
        router.swapSingleTokenExactIn(weighted, pair, wif, 90e18, 0, type(uint256).max, false, "");
        vm.stopPrank();

        uint256 indexSupplyBefore = IERC20(indexA).totalSupply();
        Harvest memory h = _harvest(weighted);
        assertEq(h.fees.length, 3, "fee count");
        for (uint256 i = 0; i < 3; ++i) {
            assertGt(h.fees[i], 0, "a token earned no fees");
            assertGt(h.toIndex[i], 0, "a fee token did not go into the index");
        }
        assertEq(IERC20(indexA).totalSupply() - indexSupplyBefore, h.indexBptStreamed, "index BPT not streamed");
        assertGt(h.polBpt, 0, "no POL");
        assertEq(treasury.protocolOwnedBpt(weighted), h.polBpt, "POL not booked");
    }

    function testSelfRewardingOnlyCurator() public {
        vm.expectRevert(StakingRewardsLauncher.SenderIsNotCurator.selector);
        _launchSelfRewarding();
    }

    /// @dev A self-rewarding pool: its staker share goes back into it (one-sided, capped), and stakers earn its BPT,
    /// though only two of its three tokens trade.
    function testSelfRewardingPool() public {
        vm.prank(admin);
        address self = _launchSelfRewarding();

        assertTrue(treasury.isSelfRewarding(self), "not self-rewarding");
        assertTrue(treasury.isIndexPool(self), "not an index pool");
        assertEq(treasury.getPoolConfig(self).indexPool, self, "index is not itself");
        IERC20[] memory rewardTokens = rack.getRewardTokens();
        assertEq(address(rewardTokens[rewardTokens.length - 1]), self, "not a reward token");
        _assertStakingRewardsRoles(self);

        _initWeighted(self, _tokens3(wif, pair, usdc), _amounts3(80_000e18, 5_000e18, 5_000e18));
        _stake(alice, 1_000e18);
        _trade(self, wif, 2_000e18);

        uint256 supplyBefore = IERC20(self).totalSupply();
        Harvest memory h = _harvest(self);

        assertGt(h.indexBptStreamed, 0, "nothing streamed");
        assertEq(IERC20(self).balanceOf(address(rack)), h.indexBptStreamed, "rack did not get the BPT");
        assertEq(IERC20(self).totalSupply() - supplyBefore, h.indexBptStreamed + h.polBpt, "BPT minted != streamed + POL");
        assertEq(treasury.protocolOwnedBpt(self), h.polBpt, "POL not booked");
        // The treasury holds only the POL: the stakers' BPT went to the rack.
        assertEq(IERC20(self).balanceOf(address(treasury)), h.polBpt, "stakers' BPT left in the treasury");

        // The add takes the staker share, up to the cap (the pool's 1% fee of its balance of each token).
        StakingRewardsTreasury.Ledger memory ledger = treasury.getLedger(self);
        (, , uint256[] memory balancesRaw, ) = vault.getPoolTokenInfo(self);
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(h.toIndex[i] + ledger.reserved[i], h.fees[i].mulDown(STAKER_SHARE), "staker share lost");
            assertLe(h.toIndex[i], (balancesRaw[i] - h.toIndex[i] - h.pol[i]).mulDown(SWAP_FEE), "over the cap");
        }
        assertGt(h.toIndex[_wifIndexIn(self)], 0, "WIF fees not added");

        // Stakers earn its BPT over the stream.
        vm.warp(block.timestamp + rack.REWARD_DURATION());
        vm.prank(alice);
        rack.getReward(IERC20(self));
        assertApproxEqAbs(IERC20(self).balanceOf(alice), h.indexBptStreamed, 1e6, "staker did not earn the BPT");
    }

    /// @dev Other staking rewards pools holding its tokens can feed a self-rewarding pool as their index.
    function testSelfRewardingPoolAsIndex() public {
        vm.prank(admin);
        address self = _launchSelfRewarding();
        _initWeighted(self, _tokens3(wif, pair, usdc), _amounts3(80_000e18, 5_000e18, 5_000e18));

        // Anyone launches a WIF/WETH ReClamm pool on it.
        vm.prank(bob);
        address feeder = _launchReClamm(_params(wif, self));
        vm.startPrank(lp);
        _initPool(feeder, IReClammPool(feeder).computeInitialBalancesRaw(wif, SEED), 0);
        vm.stopPrank();

        _stake(alice, 1_000e18);
        _trade(feeder, wif, 2_000e18);
        uint256 supplyBefore = IERC20(self).totalSupply();
        Harvest memory h = _harvest(feeder);
        assertGt(h.toIndex[wifIdx], 0, "nothing added to the self-rewarding pool");
        assertGt(h.indexBptStreamed, 0, "nothing streamed");
        assertEq(IERC20(self).totalSupply() - supplyBefore, h.indexBptStreamed, "BPT minted != streamed");
    }

    function _wifIndexIn(address rewardsPool) internal view returns (uint256) {
        IERC20[] memory poolTokens = vault.getPoolTokens(rewardsPool);
        for (uint256 i = 0; i < poolTokens.length; ++i) {
            if (poolTokens[i] == wif) return i;
        }
        revert("no WIF");
    }

    // WIF 50%, WETH 25%, USDC 25%, launched by the caller.
    function _launchSelfRewarding() internal returns (address) {
        return
            launcher.createSelfRewardingWeightedPool(
                _stakingRewardsParams(_defaultParams()),
                _weightedParams(_tokens3(wif, pair, usdc), _weights3(50e16, 25e16, 25e16)),
                bytes32(_salt++)
            );
    }

    // Initializes a weighted pool with `amounts` of `list` (in any order).
    function _initWeighted(address weighted, IERC20[] memory list, uint256[] memory amounts) internal {
        IERC20[] memory poolTokens = vault.getPoolTokens(weighted);
        uint256[] memory sorted = new uint256[](poolTokens.length);
        for (uint256 i = 0; i < poolTokens.length; ++i) {
            for (uint256 j = 0; j < list.length; ++j) {
                if (list[j] == poolTokens[i]) sorted[i] = amounts[j];
            }
        }
        vm.startPrank(lp);
        _initPool(weighted, sorted, 0);
        vm.stopPrank();
    }

    function _amounts3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](3);
        (amounts[0], amounts[1], amounts[2]) = (a, b, c);
    }

    function _assertStakingRewardsRoles(address rewardsPool) internal view {
        PoolRoleAccounts memory roles = vault.getPoolRoleAccounts(rewardsPool);
        assertEq(roles.poolCreator, address(treasury), "pool creator is not the treasury");
        assertEq(roles.swapFeeManager, address(0), "swap fee manager set");
        assertEq(roles.pauseManager, address(0), "pause manager set");
        assertEq(feeController.getPoolCreatorSwapFeePercentage(rewardsPool), CREATOR_FEE, "creator fee not set");
        assertEq(vault.getStaticSwapFeePercentage(rewardsPool), SWAP_FEE, "swap fee");
    }

    /***************************************************************************
                                    Curator
    ***************************************************************************/

    function testAllowIndexPoolOnlyCuratorAndOnce() public {
        address index = _createIndexA(true);
        vm.expectRevert(StakingRewardsTreasury.SenderIsNotCurator.selector);
        treasury.allowIndexPool(index);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsTreasury.IndexPoolAlreadyAllowed.selector, indexA));
        treasury.allowIndexPool(indexA);
    }

    function testAllowIndexPoolRejectsProportionalOnly() public {
        // A ReClamm pool (like a staking rewards pool) only takes proportional liquidity.
        vm.prank(admin);
        vm.expectRevert(StakingRewardsTreasury.IndexPoolNeedsUnbalancedLiquidity.selector);
        treasury.allowIndexPool(pool);
    }

    function testRewardTokensCapped() public {
        uint256 max = rack.MAX_REWARD_TOKENS();
        for (uint256 i = rack.getRewardTokens().length; i < max; ++i) {
            address index = _createIndexA(true);
            vm.prank(admin);
            treasury.allowIndexPool(index);
        }
        address oneTooMany = _createIndexA(true);
        vm.prank(admin);
        vm.expectRevert(StakingRewardsRack.TooManyRewardTokens.selector);
        treasury.allowIndexPool(oneTooMany);
    }

    /***************************************************************************
                                    Fees
    ***************************************************************************/

    function testSwapFeeChargedBothWays() public {
        _checkFeeCharged(wif, pair, SWAP_FEE);
        _checkFeeCharged(pair, wif, SWAP_FEE);
    }

    function _checkFeeCharged(IERC20 tokenIn, IERC20 tokenOut, uint256 fee) internal {
        uint256 amountIn = 100e18;
        uint256 aggregatePct = vault.getPoolConfig(pool).aggregateSwapFeePercentage;
        uint256 aggregateBefore = vault.getAggregateSwapFeeAmount(pool, tokenIn);

        vm.prank(bob);
        router.swapSingleTokenExactIn(pool, tokenIn, tokenOut, amountIn, 0, type(uint256).max, false, "");

        uint256 expected = amountIn.mulUp(fee).mulDown(aggregatePct);
        assertApproxEqAbs(
            vault.getAggregateSwapFeeAmount(pool, tokenIn) - aggregateBefore,
            expected,
            1,
            "wrong fee charged"
        );
    }

    function testQuoteEqualsSettlement__Fuzz(uint256 amount, bool sell, bool exactIn) public {
        amount = bound(amount, 1e15, 5_000e18);
        (IERC20 tokenIn, IERC20 tokenOut) = sell ? (wif, pair) : (pair, wif);
        if (sell == false || exactIn == false) {
            // Keep amounts in the pair token's scale (0.25 WETH per WIF).
            amount = amount / 4;
        }

        uint256 snapshot = vm.snapshotState();
        _prankStaticCall();
        uint256 quoted = exactIn
            ? router.querySwapSingleTokenExactIn(pool, tokenIn, tokenOut, amount, address(this), "")
            : router.querySwapSingleTokenExactOut(pool, tokenIn, tokenOut, amount, address(this), "");
        vm.revertToState(snapshot);

        vm.prank(bob);
        uint256 settled = exactIn
            ? router.swapSingleTokenExactIn(pool, tokenIn, tokenOut, amount, 0, type(uint256).max, false, "")
            : router.swapSingleTokenExactOut(
                pool,
                tokenIn,
                tokenOut,
                amount,
                type(uint256).max,
                type(uint256).max,
                false,
                ""
            );

        assertEq(quoted, settled, "quote != settlement");
    }

    function testUnbalancedLiquidityRefused() public {
        // ReClamm only takes proportional liquidity.
        vm.prank(bob);
        vm.expectRevert(IVaultErrors.DoesNotSupportUnbalancedLiquidity.selector);
        router.addLiquidityUnbalanced(pool, _amounts(1_000e18, 0), 0, false, "");
    }

    /***************************************************************************
                                    Harvest
    ***************************************************************************/

    function testHarvestSplitsAndConserves() public {
        _stake(alice, 10_000e18);
        _trade(pool, wif, 2_000e18);

        uint256[] memory treasuryBefore = _balances(address(treasury));
        uint256 bptBefore = treasury.protocolOwnedBpt(pool);
        uint256 supplyBefore = IERC20(pool).totalSupply();
        uint256 indexSupplyBefore = IERC20(indexA).totalSupply();

        Harvest memory h = _harvest(pool);

        assertGt(h.fees[wifIdx], 0, "no sell fees");
        assertGt(h.fees[pairIdx], 0, "no buy fees");

        uint256[] memory treasuryAfter = _balances(address(treasury));
        StakingRewardsTreasury.Ledger memory ledger = treasury.getLedger(pool);
        for (uint256 i = 0; i < 2; ++i) {
            // Below the cap, the whole staker share goes into the index.
            assertEq(h.toIndex[i], h.fees[i].mulDown(STAKER_SHARE), "staker share not added to the index");
            // Conservation: carry-in + fees = index + POL + carry-over.
            assertEq(treasuryBefore[i] + h.fees[i], h.toIndex[i] + h.pol[i] + treasuryAfter[i], "tokens not conserved");
        }
        assertEq(ledger.reserved[0] + ledger.reserved[1], 0, "staker share left reserved");
        assertEq(treasuryAfter[0], ledger.carry[0], "token 0 balance != ledger");
        assertEq(treasuryAfter[1], ledger.carry[1], "token 1 balance != ledger");

        assertGt(h.indexBptStreamed, 0, "no index BPT");
        assertEq(IERC20(indexA).totalSupply() - indexSupplyBefore, h.indexBptStreamed, "index BPT mismatch");
        assertEq(IERC20(indexA).balanceOf(address(rack)), h.indexBptStreamed, "rack did not get the index BPT");
        assertEq(rack.getRewardState(IERC20(indexA)).rewardReserve, h.indexBptStreamed, "rack reserve mismatch");
        assertEq(IERC20(indexA).balanceOf(address(treasury)), 0, "index BPT left in the treasury");

        assertGt(h.polBpt, 0, "no POL");
        assertEq(treasury.protocolOwnedBpt(pool) - bptBefore, h.polBpt, "BPT != POL");
        assertEq(IERC20(pool).totalSupply() - supplyBefore, h.polBpt, "supply grew by something else");
    }

    function testPoolsShareTreasuryButNotTokens() public {
        _stake(alice, 10_000e18);
        // Lots of sells, so both ledgers carry unpaired WIF / USDC and some WETH over.
        _trade(pool, wif, 20_000e18);
        _trade(poolB, usdc, 20_000e18);

        _harvest(pool);
        StakingRewardsTreasury.Ledger memory ledgerB = treasury.getLedger(poolB);
        assertEq(ledgerB.carry[0] + ledgerB.carry[1] + ledgerB.reserved[0] + ledgerB.reserved[1], 0, "A's harvest booked to B");

        _harvest(poolB);
        // The treasury holds exactly what the two ledgers say: nothing of one pool went to the other.
        _assertBalanceMatchesLedgers(pair);
        _assertBalanceMatchesLedgers(wif);
        _assertBalanceMatchesLedgers(usdc);

        // Harvests are rate-limited per pool: both pools again a day later, in either order.
        vm.warp(block.timestamp + treasury.HARVEST_INTERVAL());
        _harvest(poolB);
        _harvest(pool);
        _assertBalanceMatchesLedgers(pair);
    }

    function testStakersEarnEveryIndex() public {
        _stake(alice, 10_000e18);
        _trade(pool, wif, 2_000e18);
        _trade(poolB, usdc, 2_000e18);
        uint256 streamedA = _harvest(pool).indexBptStreamed;
        uint256 streamedB = _harvest(poolB).indexBptStreamed;
        assertGt(streamedA, 0, "nothing streamed from A");
        assertGt(streamedB, 0, "nothing streamed from B");

        vm.warp(block.timestamp + 7 days);

        // One token at a time.
        vm.prank(alice);
        rack.getReward(IERC20(indexB));
        assertApproxEqAbs(IERC20(indexB).balanceOf(alice), streamedB, 1e6, "index B not paid");
        assertEq(IERC20(indexA).balanceOf(alice), 0, "claimed index A too");

        // Then the rest.
        vm.prank(alice);
        rack.getReward();
        assertApproxEqAbs(IERC20(indexA).balanceOf(alice), streamedA, 1e6, "index A not paid");
        assertLe(IERC20(indexA).balanceOf(alice), streamedA, "paid more than streamed");
    }

    function testWithdrawNeverPaysRewards() public {
        _stake(alice, 10_000e18);
        _trade(pool, wif, 2_000e18);
        _harvest(pool);
        vm.warp(block.timestamp + 1 days);

        uint256 earnedBefore = rack.earned(IERC20(indexA), alice);
        assertGt(earnedBefore, 0, "nothing earned");

        uint256 wifBefore = wif.balanceOf(alice);
        vm.prank(alice);
        rack.withdraw(10_000e18);

        assertEq(wif.balanceOf(alice) - wifBefore, 10_000e18, "stake not returned");
        assertEq(IERC20(indexA).balanceOf(alice), 0, "withdraw paid rewards");
        assertEq(rack.earned(IERC20(indexA), alice), earnedBefore, "earned rewards lost on withdraw");
    }

    function testIndexAddCappedAndCarried() public {
        _stake(alice, 10_000e18);
        // Big trades: the staker share of the sell fees is over 1% of the index's WIF.
        for (uint256 i = 0; i < 4; ++i) {
            _trade(pool, wif, 20_000e18);
        }

        uint256 indexWifBalance = _indexBalance(indexA, wif);
        Harvest memory h = _harvest(pool);

        uint256 wifReserved = _reserved(pool, wifIdx);
        assertEq(h.toIndex[wifIdx], indexWifBalance.mulDown(treasury.MAX_INDEX_ADD_RATIO()), "WIF add not capped");
        assertGt(wifReserved, 0, "nothing carried over");
        assertEq(h.fees[wifIdx].mulDown(STAKER_SHARE), h.toIndex[wifIdx] + wifReserved, "staker WIF lost");
        assertGe(wif.balanceOf(address(treasury)), wifReserved, "reserved WIF spent");

        // The next harvest adds more of it, with no new fees.
        vm.warp(block.timestamp + treasury.HARVEST_INTERVAL());
        _harvest(pool);
        assertLt(_reserved(pool, wifIdx), wifReserved, "carry-over not added");
    }

    function testIndexAddFailureKeepsStakerShare() public {
        _stake(alice, 10_000e18);
        _trade(pool, wif, 2_000e18);
        vault.manualPausePool(indexA);

        Harvest memory h = _harvest(pool);

        assertEq(h.toIndex[0] + h.toIndex[1], 0, "added to a paused index");
        assertEq(h.indexBptStreamed, 0, "streamed without an index add");
        assertGt(h.polBpt, 0, "POL blocked");
        uint256[2] memory reserved = [_reserved(pool, 0), _reserved(pool, 1)];
        for (uint256 i = 0; i < 2; ++i) {
            assertEq(reserved[i], h.fees[i].mulDown(STAKER_SHARE), "staker share not reserved");
            assertGe(_token(i).balanceOf(address(treasury)), reserved[i], "reserved tokens went to POL");
        }

        vault.manualUnpausePool(indexA);
        vm.warp(block.timestamp + treasury.HARVEST_INTERVAL());
        h = _harvest(pool);
        assertEq(h.toIndex[0], reserved[0], "reserve 0 not added after unpause");
        assertEq(h.toIndex[1], reserved[1], "reserve 1 not added after unpause");
        assertGt(h.indexBptStreamed, 0, "nothing streamed after unpause");
    }

    function testPolFailureDoesNotBlockStakers() public {
        _stake(alice, 1_000e18);
        _trade(pool, wif, 2_000e18);
        vault.manualPausePool(pool);

        Harvest memory h = _harvest(pool);

        assertGt(h.indexBptStreamed, 0, "stakers not paid");
        assertEq(h.polBpt, 0, "POL added to a paused pool");
    }

    function testStakersStreamOverSevenDays() public {
        _stake(alice, 10_000e18);
        _trade(pool, wif, 2_000e18);
        uint256 streamed = _harvest(pool).indexBptStreamed;

        vm.warp(block.timestamp + 3.5 days);
        assertApproxEqRel(rack.earned(IERC20(indexA), alice), streamed / 2, 1e12, "half not streamed at 3.5 days");

        vm.warp(block.timestamp + 3.5 days);
        vm.prank(alice);
        rack.getReward();
        uint256 received = IERC20(indexA).balanceOf(alice);
        assertApproxEqAbs(received, streamed, 1e6, "not all streamed at 7 days");
        assertLe(received, streamed, "paid more than streamed");
    }

    function testJitStakerGetsTimeShare() public {
        _stake(alice, 1_000e18);
        _trade(pool, wif, 2_000e18);
        uint256 streamed = _harvest(pool).indexBptStreamed;

        // Bob stakes 100x Alice's stake right after the harvest, for one hour.
        _stake(bob, 100_000e18);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(bob);
        rack.exit();

        assertLe(IERC20(indexA).balanceOf(bob), streamed / 168, "JIT staker beat their time share");
    }

    function testHarvestRateLimited() public {
        treasury.harvest(pool);
        uint256 next = block.timestamp + treasury.HARVEST_INTERVAL();

        vm.warp(next - 1);
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsTreasury.HarvestTooSoon.selector, next));
        treasury.harvest(pool);

        vm.warp(next);
        treasury.harvest(pool);
    }

    function testHarvestUnknownPool() public {
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsTreasury.UnknownPool.selector, indexA));
        treasury.harvest(indexA);
    }

    function testNoStakersAllToPol() public {
        _trade(pool, wif, 2_000e18);
        uint256 indexSupplyBefore = IERC20(indexA).totalSupply();

        Harvest memory h = _harvest(pool);

        assertEq(h.toIndex[0] + h.toIndex[1], 0, "added to the index with no stakers");
        assertEq(h.indexBptStreamed, 0, "streamed with no stakers");
        assertEq(IERC20(indexA).totalSupply(), indexSupplyBefore, "index BPT minted");
        assertEq(_reserved(pool, 0) + _reserved(pool, 1), 0, "reserved with no stakers");
        assertGt(h.polBpt, 0, "no POL");
    }

    function testUnallocatedStreamRecycledAndRestreamed() public {
        _stake(alice, 1_000e18);
        _trade(pool, wif, 2_000e18);
        _harvest(pool);

        // Everyone leaves; the next day of the stream has nobody to go to.
        vm.prank(alice);
        rack.exit();
        vm.warp(block.timestamp + 1 days);

        // The next harvest (nobody staked) takes it back and holds it for index A.
        _harvest(pool);
        uint256 recycled = treasury.recycledBpt(indexA);
        assertGt(recycled, 0, "nothing recycled");
        assertEq(IERC20(indexA).balanceOf(address(treasury)), recycled, "recycled BPT not held");
        assertEq(rack.getRewardState(IERC20(indexA)).unallocated, 0, "unallocated left");

        // It is streamed again with the next harvest that has stakers.
        _stake(bob, 1_000e18);
        vm.warp(block.timestamp + treasury.HARVEST_INTERVAL());
        assertGe(_harvest(pool).indexBptStreamed, recycled, "recycled BPT not restreamed");
        assertEq(treasury.recycledBpt(indexA), 0, "recycled BPT left");
        assertEq(IERC20(indexA).balanceOf(address(treasury)), 0, "index BPT left in the treasury");
    }

    function testPolGrowsEveryHarvest() public {
        _stake(alice, 1_000e18);
        uint256 bpt = treasury.protocolOwnedBpt(pool);
        for (uint256 i = 0; i < 3; ++i) {
            _trade(pool, wif, 2_000e18);
            _harvest(pool);
            assertGt(treasury.protocolOwnedBpt(pool), bpt, "POL did not grow");
            bpt = treasury.protocolOwnedBpt(pool);
            vm.warp(block.timestamp + treasury.HARVEST_INTERVAL());
        }
    }

    /***************************************************************************
                                Access control
    ***************************************************************************/

    function testRackTreasuryOnly() public {
        vm.expectRevert(StakingRewardsRack.SenderIsNotTreasury.selector);
        rack.notifyRewardAmount(IERC20(indexA), 1);

        vm.expectRevert(StakingRewardsRack.SenderIsNotTreasury.selector);
        rack.addRewardToken(IERC20(address(usdt)));

        vm.expectRevert(StakingRewardsRack.SenderIsNotTreasury.selector);
        rack.recycle(IERC20(indexA));
    }

    function testRackRejectsBadRewards() public {
        vm.startPrank(address(treasury));
        vm.expectRevert(StakingRewardsRack.RewardTooHigh.selector);
        rack.notifyRewardAmount(IERC20(indexA), 1);

        vm.expectRevert(abi.encodeWithSelector(StakingRewardsRack.NotRewardToken.selector, usdt));
        rack.notifyRewardAmount(IERC20(address(usdt)), 1);

        vm.expectRevert(abi.encodeWithSelector(StakingRewardsRack.InvalidRewardToken.selector, wif));
        rack.addRewardToken(wif);

        vm.expectRevert(abi.encodeWithSelector(StakingRewardsRack.InvalidRewardToken.selector, indexA));
        rack.addRewardToken(IERC20(indexA));
        vm.stopPrank();
    }

    function testCallbacksOnlyVault() public {
        vm.expectRevert(StakingRewardsTreasury.SenderIsNotVault.selector);
        treasury.addLiquidityHook(pool, 1e18, _amounts(1e18, 1e18));

        vm.expectRevert(StakingRewardsTreasury.SenderIsNotVault.selector);
        treasury.addToIndexHook(pool, new uint256[](6));
    }
}

contract StakingRewardsNoProtocolFeeTest is StakingRewardsTest {}

contract StakingRewardsProtocolFeeTest is StakingRewardsTest {
    function setUp() public override {
        vaultMockInitialProtocolSwapFeePercentage = 20e16;
        super.setUp();
    }
}
