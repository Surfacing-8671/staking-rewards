// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Vm } from "forge-std/Vm.sol";

import { PoolRoleAccounts } from "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { InputHelpers } from "@bush.fi/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { BaseVaultTest } from "@bush.fi/v3-vault/test/foundry/utils/BaseVaultTest.sol";

import { WeightedPoolFactory } from "../../../contracts/weighted/WeightedPoolFactory.sol";
import { ReClammPoolFactory } from "../../../contracts/reclamm/ReClammPoolFactory.sol";
import { ReClammPoolHelper } from "../../../contracts/reclamm/ReClammPoolHelper.sol";
import { IReClammPool } from "../../../contracts/reclamm/interfaces/IReClammPool.sol";
import {
    StakingRewardsLauncher,
    StakingRewardsParams,
    StakingRewardsReClammParams,
    StakingRewardsWeightedParams
} from "../../../contracts/staking-rewards/StakingRewardsLauncher.sol";
import { StakingRewardsTreasury } from "../../../contracts/staking-rewards/StakingRewardsTreasury.sol";
import { StakingRewardsRack } from "../../../contracts/staking-rewards/StakingRewardsRack.sol";

/**
 * @notice Two staking rewards ReClamm pools, launched through the launcher, sharing one treasury and one WIF staking rack:
 * - `pool` (A): `dai` (the $WIF stand-in) / `weth`, feeding index A: a weighted pool of WIF 40%, and WETH and four
 *   RWA stand-ins (`usdc`, `usdt`, `wsteth`, and the 6-decimal `usdc6Decimals`) at 12% each;
 * - `poolB`: `usdc` (another base token) / `weth`, feeding index B: USDC 40%, WETH 30%, WSTETH 30%.
 * Both pools hold WETH, so their ledgers must keep it apart. WIF stakers earn both index BPTs.
 *
 * Each staking rewards pool is seeded with 80,000 of its base token at 0.25 WETH (range 0.1 to 0.5), with a 1% swap fee,
 * 50% creator fee and 50% of harvests to stakers. The indexes are seeded small (10,000 units) so the
 * 1% per-harvest cap can be hit. The curator is `admin`.
 *
 * Suites that build on it run with a 0% protocol swap fee unless they set `vaultMockInitialProtocolSwapFeePercentage`.
 */
abstract contract BaseStakingRewardsTest is BaseVaultTest {
    using FixedPoint for uint256;

    uint256 internal constant SWAP_FEE = 1e16;
    uint256 internal constant CREATOR_FEE = 50e16;
    uint256 internal constant STAKER_SHARE = 50e16;

    uint256 internal constant SEED = 80_000e18;

    // The `Harvested` event, by staking rewards pool (Vault) token index.
    struct Harvest {
        uint256[] fees;
        uint256[] toIndex;
        uint256 indexBptStreamed;
        uint256[] pol;
        uint256 polBpt;
    }

    // A two-token launch, flat: the launcher's settings, the token pair and the index.
    struct LaunchParams {
        string name;
        string symbol;
        IERC20 baseToken;
        IERC20 quoteToken;
        uint256 swapFeePercentage;
        uint256 creatorFeePercentage;
        uint256 stakerShare;
        address indexPool;
    }

    StakingRewardsLauncher internal launcher;
    ReClammPoolFactory internal reClammFactory;
    WeightedPoolFactory internal weightedFactory;
    StakingRewardsTreasury internal treasury;
    StakingRewardsRack internal rack;
    address internal indexA;
    address internal indexB;
    address internal poolB;
    IERC20 internal wif;
    IERC20 internal pair;
    uint256 internal wifIdx;
    uint256 internal pairIdx;

    uint256 internal _salt;

    function setUp() public virtual override {
        super.setUp();

        // The second staking rewards pool, on its own index.
        indexB = _createIndexPool(_tokens3(usdc, pair, wsteth), _weights3(40e16, 30e16, 30e16));
        vm.prank(admin);
        treasury.allowIndexPool(indexB);
        poolB = _launchReClamm(_params(usdc, indexB));
        vm.startPrank(lp);
        _initPool(poolB, IReClammPool(poolB).computeInitialBalancesRaw(usdc, SEED), 0);
        _initPool(indexB, _indexSeed(indexB), 0);
        vm.stopPrank();

        vm.prank(alice);
        wif.approve(address(rack), type(uint256).max);
        vm.prank(bob);
        wif.approve(address(rack), type(uint256).max);
    }

    function createPoolFactory() internal override returns (address) {
        wif = IERC20(address(dai));
        pair = IERC20(address(weth));
        (wifIdx, pairIdx) = getSortedIndexes(address(wif), address(pair));

        weightedFactory = new WeightedPoolFactory(vault, 365 days, "Weighted Factory v1", "Weighted Pool v1");
        ReClammPoolHelper helper = new ReClammPoolHelper(vault);
        reClammFactory = new ReClammPoolFactory(vault, helper, 365 days, "ReClamm Factory v1", "ReClamm Pool v1");
        launcher = new StakingRewardsLauncher(reClammFactory, weightedFactory, wif, admin);
        treasury = launcher.treasury();
        rack = treasury.rack();
        vm.label(address(launcher), "staking rewards launcher");
        vm.label(address(treasury), "treasury");
        vm.label(address(rack), "rack");
        return address(launcher);
    }

    function createPool() internal override returns (address newPool, bytes memory) {
        indexA = _createIndexA(true);
        vm.prank(admin);
        treasury.allowIndexPool(indexA);

        newPool = _launchReClamm(_params(wif, indexA));
        vm.label(newPool, "staking rewards pool A");
        return (newPool, "");
    }

    function initPool() internal override {
        vm.startPrank(lp);
        _initPool(pool, IReClammPool(pool).computeInitialBalancesRaw(wif, SEED), 0);
        _initPool(indexA, _indexSeed(indexA), 0);
        vm.stopPrank();
    }

    function _params(IERC20 baseToken, address indexPool) internal view returns (LaunchParams memory) {
        return
            LaunchParams({
                name: "Staking Rewards",
                symbol: "SRP",
                baseToken: baseToken,
                quoteToken: pair,
                swapFeePercentage: SWAP_FEE,
                creatorFeePercentage: CREATOR_FEE,
                stakerShare: STAKER_SHARE,
                indexPool: indexPool
            });
    }

    function _defaultParams() internal view returns (LaunchParams memory) {
        return _params(wif, indexA);
    }

    function _stakingRewardsParams(LaunchParams memory params) internal pure returns (StakingRewardsParams memory) {
        return
            StakingRewardsParams({
                name: params.name,
                symbol: params.symbol,
                swapFeePercentage: params.swapFeePercentage,
                creatorFeePercentage: params.creatorFeePercentage,
                stakerShare: params.stakerShare
            });
    }

    // The base token at 0.25 of the quote token, in a range of 0.1 to 0.5.
    function _reClammParams(LaunchParams memory params) internal pure returns (StakingRewardsReClammParams memory) {
        return
            StakingRewardsReClammParams({
                baseToken: params.baseToken,
                quoteToken: params.quoteToken,
                initialMinPrice: 0.1e18,
                initialMaxPrice: 0.5e18,
                initialTargetPrice: 0.25e18,
                dailyPriceShiftExponent: 10e16,
                centerednessMargin: 20e16
            });
    }

    function _launchReClamm(LaunchParams memory params) internal returns (address) {
        return
            launcher.createReClammPool(
                _stakingRewardsParams(params),
                _reClammParams(params),
                params.indexPool,
                bytes32(_salt++)
            );
    }

    function _weightedParams(
        IERC20[] memory list,
        uint256[] memory weights
    ) internal pure returns (StakingRewardsWeightedParams memory) {
        return StakingRewardsWeightedParams({ tokens: list, weights: weights });
    }

    // A two-token weighted pool: the base token at `baseTokenWeight`, the quote token the rest.
    function _launchWeighted(LaunchParams memory params, uint256 baseTokenWeight) internal returns (address) {
        IERC20[] memory list = new IERC20[](2);
        (list[0], list[1]) = (params.baseToken, params.quoteToken);
        uint256[] memory weights = new uint256[](2);
        (weights[0], weights[1]) = (baseTokenWeight, FixedPoint.ONE - baseTokenWeight);
        return
            launcher.createWeightedPool(
                _stakingRewardsParams(params),
                _weightedParams(list, weights),
                params.indexPool,
                bytes32(_salt++)
            );
    }

    function _tokens3(IERC20 a, IERC20 b, IERC20 c) internal pure returns (IERC20[] memory list) {
        list = new IERC20[](3);
        (list[0], list[1], list[2]) = (a, b, c);
    }

    function _weights3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory weights) {
        weights = new uint256[](3);
        (weights[0], weights[1], weights[2]) = (a, b, c);
    }

    // Index A: WIF 40%, and the four RWAs and (unless `withWeth` is false) WETH sharing the other 60%.
    function _createIndexA(bool withWeth) internal returns (address) {
        uint256 count = withWeth ? 6 : 5;
        IERC20[] memory list = new IERC20[](count);
        uint256[] memory weights = new uint256[](count);
        (list[0], list[1], list[2], list[3], list[4]) = (wif, usdc, usdt, wsteth, usdc6Decimals);
        if (withWeth) list[5] = pair;
        for (uint256 i = 0; i < count; ++i) {
            weights[i] = i == 0 ? 40e16 : 60e16 / (count - 1);
        }
        return _createIndexPool(list, weights);
    }

    // `weights` in the order of `list`.
    function _createIndexPool(IERC20[] memory list, uint256[] memory weights) internal returns (address) {
        IERC20[] memory sorted = InputHelpers.sortTokens(list);
        uint256[] memory sortedWeights = new uint256[](list.length);
        for (uint256 i = 0; i < sorted.length; ++i) {
            for (uint256 j = 0; j < list.length; ++j) {
                if (list[j] == sorted[i]) sortedWeights[i] = weights[j];
            }
        }

        PoolRoleAccounts memory roles;
        return
            weightedFactory.create(
                "Index",
                "IDX",
                vault.buildTokenConfig(sorted),
                sortedWeights,
                roles,
                1e16, // 1% swap fee
                address(0),
                false, // no donations
                false, // unbalanced liquidity allowed
                bytes32(_salt++)
            );
    }

    // 10,000 "units", split by weight; the 6-decimal token in its own decimals.
    function _indexSeed(address index) internal view returns (uint256[] memory amounts) {
        IERC20[] memory list = vault.getPoolTokens(index);
        (bool ok, bytes memory data) = index.staticcall(abi.encodeWithSignature("getNormalizedWeights()"));
        require(ok, "no weights");
        uint256[] memory weights = abi.decode(data, (uint256[]));

        amounts = new uint256[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            amounts[i] = (10_000 * weights[i]) / (list[i] == usdc6Decimals ? 1e12 : 1);
        }
    }

    /***************************************************************************
                                    Helpers
    ***************************************************************************/

    function _stake(address account, uint256 amount) internal {
        vm.prank(account);
        rack.stake(amount);
    }

    // A sell of `amount` of the base token and a buy of about the same value, so both tokens collect fees.
    function _trade(address rewardsPool, IERC20 baseToken, uint256 amount) internal {
        vm.startPrank(bob);
        router.swapSingleTokenExactIn(rewardsPool, baseToken, pair, amount, 0, type(uint256).max, false, "");
        router.swapSingleTokenExactIn(rewardsPool, pair, baseToken, amount / 4, 0, type(uint256).max, false, "");
        vm.stopPrank();
    }

    function _harvest(address rewardsPool) internal returns (Harvest memory) {
        vm.recordLogs();
        treasury.harvest(rewardsPool);
        return _harvestedEvent(rewardsPool);
    }

    function _reserved(address rewardsPool, uint256 index) internal view returns (uint256) {
        StakingRewardsTreasury.Ledger memory ledger = treasury.getLedger(rewardsPool);
        return ledger.reserved[index];
    }

    // The treasury's balance of `token` equals what the two pools' ledgers hold of it.
    function _assertBalanceMatchesLedgers(IERC20 token) internal view {
        uint256 booked;
        address[2] memory pools = [pool, poolB];
        for (uint256 i = 0; i < 2; ++i) {
            StakingRewardsTreasury.PoolConfig memory config = treasury.getPoolConfig(pools[i]);
            StakingRewardsTreasury.Ledger memory ledger = treasury.getLedger(pools[i]);
            for (uint256 k = 0; k < config.tokens.length; ++k) {
                if (config.tokens[k] == token) booked += ledger.reserved[k] + ledger.carry[k];
            }
        }
        assertEq(token.balanceOf(address(treasury)), booked, "treasury balance != ledgers");
    }

    function _indexBalance(address index, IERC20 token) internal view returns (uint256) {
        (IERC20[] memory list, , uint256[] memory balancesRaw, ) = vault.getPoolTokenInfo(index);
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == token) return balancesRaw[i];
        }
        revert("token not in index");
    }

    function _token(uint256 index) internal view returns (IERC20) {
        return index == wifIdx ? wif : pair;
    }

    function _amounts(uint256 wifAmount, uint256 pairAmount) internal view returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[wifIdx] = wifAmount;
        amounts[pairIdx] = pairAmount;
    }

    function _balances(address account) internal view returns (uint256[] memory balances) {
        balances = new uint256[](2);
        balances[0] = _token(0).balanceOf(account);
        balances[1] = _token(1).balanceOf(account);
    }

    function _harvestedEvent(address rewardsPool) internal returns (Harvest memory) {
        bytes32 topic = StakingRewardsTreasury.Harvested.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(treasury) &&
                logs[i].topics[0] == topic &&
                logs[i].topics[1] == bytes32(uint256(uint160(rewardsPool)))
            ) {
                return _decodeHarvest(logs[i].data);
            }
        }
        revert("no Harvested event");
    }

    function _decodeHarvest(bytes memory data) internal pure returns (Harvest memory h) {
        (h.fees, h.toIndex, h.indexBptStreamed, h.pol, h.polBpt) = abi.decode(
            data,
            (uint256[], uint256[], uint256, uint256[], uint256)
        );
    }
}
