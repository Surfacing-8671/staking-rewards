// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Vm } from "forge-std/Vm.sol";

import { IVaultErrors } from "@bush.fi/v3-interfaces/contracts/vault/IVaultErrors.sol";

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { IReClammPool } from "../../../contracts/reclamm/interfaces/IReClammPool.sol";
import { StakingRewardsTreasury } from "../../../contracts/staking-rewards/StakingRewardsTreasury.sol";
import { StakingRewardsRack } from "../../../contracts/staking-rewards/StakingRewardsRack.sol";

import { BaseStakingRewardsTest } from "../utils/BaseStakingRewardsTest.sol";

/**
 * @notice Fuzzed properties of single flows (the invariant suite covers random sequences), the edge cases the unit
 * tests leave out, and attacks: sandwiched harvests, late and dust stakers, duplicate pools, 6-decimal tokens.
 */
contract StakingRewardsFuzzTest is BaseStakingRewardsTest {
    using FixedPoint for uint256;

    function setUp() public override {
        super.setUp();
        deal(address(wif), alice, 1e30);
        deal(address(wif), bob, 1e30);
    }

    /***************************************************************************
                                    Harvest
    ***************************************************************************/

    /// @dev Whatever the fees and shares, each harvest splits new fees exactly: staker share to the index (or reserved
    /// over the cap), the rest to POL (or carried).
    function testHarvestSplit__Fuzz(uint256 stakerShare, uint256 creatorFee, uint256 swapFee, uint256 amount) public {
        LaunchParams memory params = _defaultParams();
        params.stakerShare = bound(stakerShare, 0, FixedPoint.ONE);
        params.creatorFeePercentage = bound(creatorFee, 0, launcher.MAX_CREATOR_FEE_PERCENTAGE());
        params.swapFeePercentage = bound(swapFee, 0.001e16, 10e16);
        address rewardsPool = _createAndInit(params, wif, SEED);

        _stake(alice, 1_000e18);
        _trade(rewardsPool, wif, bound(amount, 100e18, 20_000e18));
        uint256[2] memory caps = [_cap(_token(0)), _cap(_token(1))];

        Harvest memory h = _harvest(rewardsPool);
        StakingRewardsTreasury.Ledger memory ledger = treasury.getLedger(rewardsPool);
        uint256[] memory reserved = ledger.reserved;
        uint256[] memory carry = ledger.carry;

        for (uint256 i = 0; i < 2; ++i) {
            uint256 toStakers = h.fees[i].mulDown(params.stakerShare);
            assertEq(h.toIndex[i] + reserved[i], toStakers, "staker share lost");
            assertEq(h.pol[i] + carry[i], h.fees[i] - toStakers, "POL share lost");
            assertLe(h.toIndex[i], caps[i], "index add over the cap");
        }
        if (params.creatorFeePercentage == 0) {
            assertEq(h.fees[0] + h.fees[1], 0, "fees without a creator fee");
        } else if (params.creatorFeePercentage >= 0.01e16) {
            // (The fee controller keeps fee percentages to 1e11 precision, so tinier ones round to zero.)
            assertGt(h.fees[wifIdx], 0, "no fees");
        }
    }

    /// @dev Only WIF is sold, so only WIF fees: the add goes in with WIF alone.
    function testOneSidedFeesAdded() public {
        _stake(alice, 1_000e18);
        vm.prank(bob);
        router.swapSingleTokenExactIn(pool, wif, pair, 2_000e18, 0, type(uint256).max, false, "");

        Harvest memory h = _harvest(pool);
        assertEq(h.fees[pairIdx], 0, "WETH fees from a WIF sell");
        assertGt(h.toIndex[wifIdx], 0, "WIF not added");
        assertEq(h.toIndex[pairIdx], 0, "WETH added");
        assertGt(h.indexBptStreamed, 0, "nothing streamed");
    }

    /// @dev A staker share under the minimum add is skipped and stays reserved, not lost.
    function testDustFeesStayReserved() public {
        _stake(alice, 1_000e18);
        // 1e11 wei at a 1% fee, half to the creator, half of that to stakers: 2.5e8, under MIN_INDEX_ADD_SCALED18.
        vm.prank(bob);
        router.swapSingleTokenExactIn(pool, wif, pair, 1e11, 0, type(uint256).max, false, "");

        Harvest memory h = _harvest(pool);
        assertGt(h.fees[wifIdx], 0, "no fees");
        assertEq(h.toIndex[0] + h.toIndex[1], 0, "dust added");
        assertEq(_reserved(pool, wifIdx), h.fees[wifIdx].mulDown(STAKER_SHARE), "dust not reserved");
    }

    /// @dev A pool can be created on an approved index before the index is initialized: the staker share waits for it.
    function testHarvestWaitsForTheIndex() public {
        address indexC = _createIndexPool(_tokens3(wif, pair, usdt), _weights3(40e16, 30e16, 30e16));
        vm.prank(admin);
        treasury.allowIndexPool(indexC);
        address rewardsPool = _createAndInit(_params(wif, indexC), wif, SEED);

        _stake(alice, 1_000e18);
        _trade(rewardsPool, wif, 2_000e18);
        Harvest memory h = _harvest(rewardsPool);
        assertEq(h.toIndex[0] + h.toIndex[1] + h.indexBptStreamed, 0, "added to an uninitialized index");
        assertGt(h.polBpt, 0, "POL blocked");
        uint256[2] memory reserved = [_reserved(rewardsPool, 0), _reserved(rewardsPool, 1)];
        for (uint256 i = 0; i < 2; ++i) {
            assertEq(reserved[i], h.fees[i].mulDown(STAKER_SHARE), "staker share not reserved");
        }

        vm.startPrank(lp);
        _initPool(indexC, _indexSeed(indexC), 0);
        vm.stopPrank();
        vm.warp(block.timestamp + treasury.HARVEST_INTERVAL());

        h = _harvest(rewardsPool);
        assertEq(h.toIndex[0], reserved[0], "reserve 0 not added");
        assertEq(h.toIndex[1], reserved[1], "reserve 1 not added");
        assertGt(h.indexBptStreamed, 0, "nothing streamed");
    }

    /// @dev Anyone can create a second pool for the same pair and index; the two never share tokens.
    function testDuplicatePairsKeptApart__Fuzz(uint256 amountA, uint256 amountB, uint256 stakerShare) public {
        LaunchParams memory params = _defaultParams();
        params.stakerShare = bound(stakerShare, 0, FixedPoint.ONE);
        address twin = _createAndInit(params, wif, SEED / 2);

        _stake(alice, 1_000e18);
        _trade(pool, wif, bound(amountA, 100e18, 20_000e18));
        _trade(twin, wif, bound(amountB, 100e18, 10_000e18));
        _harvest(twin);
        _harvest(pool);

        address[] memory pools = new address[](3);
        (pools[0], pools[1], pools[2]) = (pool, poolB, twin);
        _assertLedgers(pools, wif);
        _assertLedgers(pools, pair);
    }

    /// @dev A pool of a 6-decimal token and an 18-decimal one: every add goes through, and the books balance.
    function testSixDecimalPool__Fuzz(uint256 amount) public {
        IERC20 usdc6 = IERC20(address(usdc6Decimals));
        deal(address(usdc6), lp, 1e18);
        deal(address(usdc6), bob, 1e18);
        address rewardsPool = _createAndInit(_params(usdc6, indexA), usdc6, 80_000e6);

        _stake(alice, 1_000e18);
        amount = bound(amount, 100e6, 20_000e6);
        vm.startPrank(bob);
        router.swapSingleTokenExactIn(rewardsPool, usdc6, pair, amount, 0, type(uint256).max, false, "");
        router.swapSingleTokenExactIn(rewardsPool, pair, usdc6, (amount * 1e12) / 4, 0, type(uint256).max, false, "");
        vm.stopPrank();

        vm.recordLogs();
        treasury.harvest(rewardsPool);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertNotEq(logs[i].topics[0], StakingRewardsTreasury.AddLiquidityFailed.selector, "an add failed");
        }

        assertGt(treasury.protocolOwnedBpt(rewardsPool), 0, "no POL");
        assertGt(IERC20(indexA).balanceOf(address(rack)), 0, "nothing streamed");
        address[] memory pools = new address[](3);
        (pools[0], pools[1], pools[2]) = (pool, poolB, rewardsPool);
        _assertLedgers(pools, usdc6);
        _assertLedgers(pools, pair);
    }

    /***************************************************************************
                                    Rack
    ***************************************************************************/

    /// @dev Two stakers split each stream by stake, and together never get more than has streamed.
    function testRewardsSplitByStake__Fuzz(uint256 stakeA, uint256 stakeB, uint256 wait) public {
        stakeA = bound(stakeA, 1e18, 1e26);
        stakeB = bound(stakeB, 1e18, 1e26);
        wait = bound(wait, 1 hours, rack.REWARD_DURATION());
        _stake(alice, stakeA);
        _stake(bob, stakeB);
        _trade(pool, wif, 2_000e18);
        uint256 streamed = _harvest(pool).indexBptStreamed;

        vm.warp(block.timestamp + wait);
        uint256 earnedA = rack.earned(IERC20(indexA), alice);
        uint256 earnedB = rack.earned(IERC20(indexA), bob);
        uint256 expected = (streamed * wait) / rack.REWARD_DURATION();
        // `rewardPerToken` rounds down: under a wei per 1e18 staked.
        uint256 tolerance = (stakeA + stakeB) / 1e18 + 1e3;

        assertLe(earnedA + earnedB, expected + 1, "paid more than streamed");
        assertApproxEqAbs(earnedA + earnedB, expected, tolerance, "stream not paid out");
        assertApproxEqAbs(earnedA, (expected * stakeA) / (stakeA + stakeB), tolerance, "not split by stake");
    }

    /// @dev A staker joining mid-stream earns only from then on.
    function testLateStakerEarnsFromJoin__Fuzz(uint256 joinAfter) public {
        uint256 duration = rack.REWARD_DURATION();
        joinAfter = bound(joinAfter, 1, duration - 1);
        _stake(alice, 1_000e18);
        _trade(pool, wif, 2_000e18);
        uint256 streamed = _harvest(pool).indexBptStreamed;

        vm.warp(block.timestamp + joinAfter);
        _stake(bob, 1_000e18);
        vm.warp(block.timestamp + duration);

        uint256 bobExpected = (streamed * (duration - joinAfter)) / duration / 2;
        uint256 earnedA = rack.earned(IERC20(indexA), alice);
        uint256 earnedB = rack.earned(IERC20(indexA), bob);
        assertApproxEqAbs(earnedB, bobExpected, 1e6, "late staker earned from before joining");
        assertApproxEqAbs(earnedA, streamed - bobExpected, 1e6, "early staker shorted");
        assertLe(earnedA + earnedB, streamed, "paid more than streamed");
    }

    /// @dev A harvest mid-stream folds what is left of the old stream into the new one: nothing is lost.
    function testStreamRolloverPaysEverything__Fuzz(uint256 gap) public {
        gap = bound(gap, treasury.HARVEST_INTERVAL(), rack.REWARD_DURATION() + 1 days);
        _stake(alice, 1_000e18);
        _trade(pool, wif, 2_000e18);
        uint256 streamed = _harvest(pool).indexBptStreamed;

        vm.warp(block.timestamp + gap);
        _trade(pool, wif, 2_000e18);
        streamed += _harvest(pool).indexBptStreamed;

        vm.warp(block.timestamp + rack.REWARD_DURATION() + 1);
        vm.prank(alice);
        rack.getReward();
        uint256 received = IERC20(indexA).balanceOf(alice);
        assertLe(received, streamed, "paid more than streamed");
        assertApproxEqAbs(received, streamed, 1e6, "rollover lost rewards");
    }

    function testRackRejectsZeroAndUnknown() public {
        vm.startPrank(alice);
        vm.expectRevert(StakingRewardsRack.ZeroAmount.selector);
        rack.stake(0);
        vm.expectRevert(StakingRewardsRack.ZeroAmount.selector);
        rack.withdraw(0);
        vm.expectRevert(abi.encodeWithSelector(StakingRewardsRack.NotRewardToken.selector, usdt));
        rack.getReward(IERC20(address(usdt)));

        rack.stake(1e18);
        vm.expectRevert();
        rack.withdraw(1e18 + 1);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(StakingRewardsRack.NotRewardToken.selector, usdt));
        rack.getRewardState(IERC20(address(usdt)));
    }

    function testAllowIndexPoolRejectsUnregistered() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IVaultErrors.PoolNotRegistered.selector, address(0xdead)));
        treasury.allowIndexPool(address(0xdead));
    }

    /***************************************************************************
                                Sandwich attacks
    ***************************************************************************/

    /**
     * @dev Whatever the index's fee, selling a fee token into the index right before a harvest and buying it back
     * right after loses money: the add is capped at the fee, so it moves the price by less than the round trip's fees.
     */
    function testSandwichingAHarvestDoesNotPay__Fuzz(
        uint256 indexFee,
        uint256 volume,
        uint256 size,
        bool sellWeth
    ) public {
        vault.manualSetStaticSwapFeePercentage(indexA, bound(indexFee, 0.05e16, 10e16));
        _stake(alice, 1_000e18);
        // Up to enough volume for the WIF staker share to hit the cap.
        volume = bound(volume, 1_000e18, 20_000e18);
        for (uint256 i = 0; i < 4; ++i) {
            _trade(pool, wif, volume);
        }

        IERC20 feeToken = sellWeth ? pair : wif;
        size = bound(size, 1e18, _indexBalance(indexA, feeToken) / 10);
        (uint256 out, uint256 back) = _sandwich(feeToken, size);
        assertLe(out, back, "sandwiching a harvest paid");
    }

    /// @dev Below 1%, the index's fee is the cap; it is read at each harvest, so it follows a fee change.
    function testIndexAddCappedByIndexFee__Fuzz(uint256 indexFee) public {
        indexFee = bound(indexFee, 0.05e16, 0.99e16);
        vault.manualSetStaticSwapFeePercentage(indexA, indexFee);
        // The Vault keeps fee percentages to 1e11 precision.
        indexFee = vault.getStaticSwapFeePercentage(indexA);
        _stake(alice, 1_000e18);
        for (uint256 i = 0; i < 4; ++i) {
            _trade(pool, wif, 20_000e18);
        }

        uint256 indexWif = _indexBalance(indexA, wif);
        Harvest memory h = _harvest(pool);
        assertEq(h.toIndex[wifIdx], indexWif.mulDown(indexFee), "WIF add not capped at the index fee");
        assertGt(_reserved(pool, wifIdx), 0, "nothing carried over");

        // The fee manager raises the fee: the next harvest lets more in, up to the 1% maximum.
        vault.manualSetStaticSwapFeePercentage(indexA, 5e16);
        vm.warp(block.timestamp + treasury.HARVEST_INTERVAL());
        indexWif = _indexBalance(indexA, wif);
        uint256 reserved = _reserved(pool, wifIdx);
        h = _harvest(pool);
        uint256 maxAdd = indexWif.mulDown(treasury.MAX_INDEX_ADD_RATIO());
        assertEq(h.toIndex[wifIdx], reserved < maxAdd ? reserved : maxAdd, "cap did not follow the fee");
    }

    /***************************************************************************
                                    Helpers
    ***************************************************************************/

    function _createAndInit(
        LaunchParams memory params,
        IERC20 referenceToken,
        uint256 referenceAmount
    ) internal returns (address rewardsPool) {
        rewardsPool = _launchReClamm(params);
        vm.startPrank(lp);
        _initPool(rewardsPool, IReClammPool(rewardsPool).computeInitialBalancesRaw(referenceToken, referenceAmount), 0);
        vm.stopPrank();
    }

    function _cap(IERC20 token) internal view returns (uint256) {
        uint256 ratio = vault.getStaticSwapFeePercentage(indexA);
        if (ratio > treasury.MAX_INDEX_ADD_RATIO()) ratio = treasury.MAX_INDEX_ADD_RATIO();
        return _indexBalance(indexA, token).mulDown(ratio);
    }

    // Bob sells `size` of `feeToken` for USDC in index A, the pool is harvested, and Bob buys `size` back.
    function _sandwich(IERC20 feeToken, uint256 size) internal returns (uint256 usdcOut, uint256 usdcBack) {
        vm.prank(bob);
        usdcOut = router.swapSingleTokenExactIn(indexA, feeToken, usdc, size, 0, type(uint256).max, false, "");
        treasury.harvest(pool);
        vm.prank(bob);
        usdcBack = router.swapSingleTokenExactOut(
            indexA,
            usdc,
            feeToken,
            size,
            type(uint256).max,
            type(uint256).max,
            false,
            ""
        );
    }

    // The treasury's balance of `token` equals what `pools`' ledgers hold of it.
    function _assertLedgers(address[] memory pools, IERC20 token) internal view {
        uint256 booked;
        for (uint256 i = 0; i < pools.length; ++i) {
            StakingRewardsTreasury.PoolConfig memory config = treasury.getPoolConfig(pools[i]);
            StakingRewardsTreasury.Ledger memory ledger = treasury.getLedger(pools[i]);
            for (uint256 k = 0; k < config.tokens.length; ++k) {
                if (config.tokens[k] == token) booked += ledger.reserved[k] + ledger.carry[k];
            }
        }
        assertEq(token.balanceOf(address(treasury)), booked, "treasury balance != ledgers");
    }
}
