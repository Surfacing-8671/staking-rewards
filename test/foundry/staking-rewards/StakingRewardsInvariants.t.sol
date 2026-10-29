// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";

import { IVaultMock } from "@bush.fi/v3-interfaces/contracts/test/IVaultMock.sol";
import { IRouter } from "@bush.fi/v3-interfaces/contracts/vault/IRouter.sol";
import { IProtocolFeeController } from "@bush.fi/v3-interfaces/contracts/vault/IProtocolFeeController.sol";
import { PoolRoleAccounts } from "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { InputHelpers } from "@bush.fi/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { WeightedPoolFactory } from "../../../contracts/weighted/WeightedPoolFactory.sol";
import { IReClammPool } from "../../../contracts/reclamm/interfaces/IReClammPool.sol";
import {
    StakingRewardsLauncher,
    StakingRewardsParams,
    StakingRewardsReClammParams,
    StakingRewardsWeightedParams
} from "../../../contracts/staking-rewards/StakingRewardsLauncher.sol";
import { StakingRewardsTreasury } from "../../../contracts/staking-rewards/StakingRewardsTreasury.sol";
import { StakingRewardsRack } from "../../../contracts/staking-rewards/StakingRewardsRack.sol";

import { BaseStakingRewardsTest } from "../utils/BaseStakingRewardsTest.sol";

/**
 * @notice Drives the staking rewards contracts through random sequences of: pool launches (two-token ReClamm, weighted with 2 to 4
 * tokens, and self-rewarding weighted by the curator; some left uninitialized) and index creation,
 * swaps, LP adds and removes, staking, withdrawing and claiming (dust cycles included), harvests, waits, pauses, and
 * attacks: sandwiched harvests, just-in-time staking, donations to the treasury and the rack, and calls that only the
 * launcher, the curator, the treasury or the Vault may make.
 *
 * A failed check can't revert here (a reverting handler call is just discarded), so it is recorded in `failure` for
 * `invariant_noFailures`.
 */
contract StakingRewardsHandler is Test {
    using FixedPoint for uint256;

    struct Env {
        IVaultMock vault;
        IRouter router;
        IPermit2 permit2;
        IProtocolFeeController feeController;
        StakingRewardsLauncher launcher;
        WeightedPoolFactory weightedFactory;
        address curator;
        IERC20 wif;
        IERC20[] tokens;
        address[] pools;
    }

    uint256 internal constant ACTOR_COUNT = 4;
    uint256 internal constant MAX_POOLS = 8;

    IVaultMock internal immutable _vault;
    IRouter internal immutable _router;
    IPermit2 internal immutable _permit2;
    IProtocolFeeController internal immutable _feeController;
    StakingRewardsLauncher internal immutable _launcher;
    StakingRewardsTreasury internal immutable _treasury;
    StakingRewardsRack internal immutable _rack;
    WeightedPoolFactory internal immutable _weightedFactory;
    address internal immutable _curator;
    IERC20 internal immutable _wif;

    IERC20[] internal _tokens;
    address[] internal _pools;
    address[] internal _actors;
    address public jitActor;
    uint256 internal _salt;

    // Ghosts.
    string public failure;
    bytes public failureData;
    mapping(address token => uint256 amount) public donatedToTreasury;
    mapping(address token => uint256 amount) public donatedToRack;
    mapping(address pool => uint256 amount) public polBpt;
    mapping(address index => uint256 amount) public notified;
    mapping(address index => uint256 amount) public recycled;
    mapping(address actor => uint256 amount) public staked;
    mapping(address pool => uint256 fee) public creatorFee;
    mapping(address pool => bool weighted) public isWeighted;
    uint256 public harvests;
    uint256 public sandwiches;
    uint256 public jits;
    uint256 public poolsCreated;
    uint256 public selfRewardingCreated;
    uint256 public indexesCreated;
    // For the rounding allowance: every call may update rewards once, losing under `totalStaked / 1e18` wei.
    uint256 public calls;
    uint256 public maxTotalStaked;

    modifier tracked() {
        calls++;
        _;
        _recordStake();
    }

    constructor(Env memory env) {
        _vault = env.vault;
        _router = env.router;
        _permit2 = env.permit2;
        _feeController = env.feeController;
        _launcher = env.launcher;
        _treasury = env.launcher.treasury();
        _rack = _treasury.rack();
        _weightedFactory = env.weightedFactory;
        _curator = env.curator;
        _wif = env.wif;
        _tokens = env.tokens;
        _pools = env.pools;

        for (uint256 i = 0; i < _tokens.length; ++i) {
            _approveRouter(_tokens[i]);
        }
        for (uint256 i = 0; i < _pools.length; ++i) {
            _approveRouter(IERC20(_pools[i]));
            creatorFee[_pools[i]] = _feeController.getPoolCreatorSwapFeePercentage(_pools[i]);
        }

        for (uint256 i = 0; i <= ACTOR_COUNT; ++i) {
            address actor = makeAddr(string.concat("staker", vm.toString(i)));
            deal(address(_wif), actor, 1e30);
            vm.prank(actor);
            _wif.approve(address(_rack), type(uint256).max);
            if (i < ACTOR_COUNT) {
                _actors.push(actor);
            } else {
                jitActor = actor;
            }
        }
    }

    /***************************************************************************
                                    Views
    ***************************************************************************/

    function getPools() external view returns (address[] memory) {
        return _pools;
    }

    // Every account that ever staked, the just-in-time one last.
    function getStakers() external view returns (address[] memory stakers) {
        stakers = new address[](ACTOR_COUNT + 1);
        for (uint256 i = 0; i < ACTOR_COUNT; ++i) {
            stakers[i] = _actors[i];
        }
        stakers[ACTOR_COUNT] = jitActor;
    }

    function getTokens() external view returns (IERC20[] memory) {
        return _tokens;
    }

    /***************************************************************************
                                Pools and indexes
    ***************************************************************************/

    /// @dev Anyone launches a ReClamm pool or a weighted pool (2 to 4 tokens) on an approved index, or the curator a
    /// self-rewarding weighted pool, with random fees, shares and weights; one in four is left uninitialized.
    function createPool(uint256 indexSeed, uint256 pairSeed, uint256 feeSeed, uint256 amountSeed) external tracked {
        if (_pools.length >= MAX_POOLS) return;

        uint256 kind = (pairSeed >> 16) % 3; // 0: ReClamm, 1: weighted on an index, 2: self-rewarding
        if (kind == 2 && _rack.getRewardTokens().length >= _rack.MAX_REWARD_TOKENS()) kind = 1;

        IERC20[] memory rewardTokens = _rack.getRewardTokens();
        address index = kind == 2 ? address(0) : address(rewardTokens[indexSeed % rewardTokens.length]);
        IERC20[] memory list = _pickTokens(kind == 2 ? _tokens : _vault.getPoolTokens(index), kind, pairSeed);
        uint256[] memory weights = _randomWeights(list.length, feeSeed);

        StakingRewardsParams memory params = StakingRewardsParams({
            name: "Staking Rewards",
            symbol: "SRP",
            // Each pool type's swap fee bounds: ReClamm 0.001% to 10%, weighted 0.05% to 10%.
            swapFeePercentage: bound(feeSeed, kind == 0 ? 0.001e16 : 0.05e16, 10e16),
            creatorFeePercentage: bound(feeSeed >> 64, 0, _launcher.MAX_CREATOR_FEE_PERCENTAGE()),
            stakerShare: bound(feeSeed >> 128, 0, _launcher.MAX_STAKER_SHARE())
        });

        address newPool;
        try this.launch(kind, params, list, weights, index, bytes32(_salt++)) returns (address created) {
            newPool = created;
        } catch (bytes memory reason) {
            _fail("launch failed", reason);
            return;
        }
        _pools.push(newPool);
        poolsCreated++;
        if (kind == 2) selfRewardingCreated++;
        creatorFee[newPool] = params.creatorFeePercentage;
        isWeighted[newPool] = kind != 0;
        _approveRouter(IERC20(newPool));

        if (_feeController.getPoolCreatorSwapFeePercentage(newPool) != params.creatorFeePercentage) {
            _fail("creator fee not set at launch", abi.encode(newPool));
        }
        if (_treasury.isSelfRewarding(newPool) != (kind == 2)) _fail("self-rewarding mismatch", abi.encode(newPool));

        if (feeSeed % 4 != 0) {
            _initialize(newPool, list[0], amountSeed);
        }
    }

    // Two distinct tokens for ReClamm, 2 to 4 for weighted, from a random start and stride (moving on to the next unused
    // one on a repeat).
    function _pickTokens(
        IERC20[] memory candidates,
        uint256 kind,
        uint256 pairSeed
    ) internal pure returns (IERC20[] memory list) {
        uint256 count = kind == 0 ? 2 : 2 + ((pairSeed >> 24) % 3);
        if (count > candidates.length) count = candidates.length;
        list = new IERC20[](count);
        uint256 position = pairSeed % candidates.length;
        uint256 stride = 1 + ((pairSeed >> 8) % (candidates.length - 1));
        for (uint256 k = 0; k < count; ++k) {
            while (_contains(list, candidates[position])) position = (position + 1) % candidates.length;
            list[k] = candidates[position];
            position = (position + stride) % candidates.length;
        }
    }

    // Random weights of at least 1% each, adding up to 100%.
    function _randomWeights(uint256 count, uint256 seed) internal pure returns (uint256[] memory weights) {
        weights = new uint256[](count);
        uint256 left = FixedPoint.ONE;
        for (uint256 k = 0; k < count; ++k) {
            uint256 room = left - (count - 1 - k) * 1e16;
            weights[k] = k == count - 1 ? left : bound(uint256(keccak256(abi.encode(seed, k))), 1e16, room / 2);
            left -= weights[k];
        }
    }

    /// @dev Called by `createPool` only (an external call, so a failed launch can be caught).
    function launch(
        uint256 kind,
        StakingRewardsParams memory params,
        IERC20[] memory list,
        uint256[] memory weights,
        address index,
        bytes32 salt
    ) external returns (address) {
        require(msg.sender == address(this), "only createPool");
        StakingRewardsWeightedParams memory weightedParams = StakingRewardsWeightedParams({ tokens: list, weights: weights });
        if (kind == 2) {
            vm.prank(_curator);
            return _launcher.createSelfRewardingWeightedPool(params, weightedParams, salt);
        }
        if (kind == 1) return _launcher.createWeightedPool(params, weightedParams, index, salt);
        return
            _launcher.createReClammPool(
                params,
                StakingRewardsReClammParams({
                    baseToken: list[0],
                    quoteToken: list[1],
                    initialMinPrice: 0.1e18,
                    initialMaxPrice: 0.5e18,
                    initialTargetPrice: 0.25e18,
                    dailyPriceShiftExponent: 10e16,
                    centerednessMargin: 20e16
                }),
                index,
                salt
            );
    }

    function initializePending(uint256 poolSeed, uint256 amountSeed) external tracked {
        address rewardsPool = _pickPool(poolSeed);
        // A self-rewarding pool is a reward token, so `togglePause` may pause it before it is initialized; the Vault
        // refuses to initialize a paused pool.
        if (_vault.isPoolInitialized(rewardsPool) || _vault.isPoolPaused(rewardsPool)) return;
        _initialize(rewardsPool, _treasury.getPoolConfig(rewardsPool).tokens[0], amountSeed);
    }

    /// @dev The curator approves a new index (2 to 4 tokens, equal weights, a 0.05% to 10% fee) mid-stream, up to the
    /// rack's cap.
    function createIndex(uint256 seed) external tracked {
        if (_rack.getRewardTokens().length >= _rack.MAX_REWARD_TOKENS()) return;

        uint256 count = 2 + (seed % 3);
        IERC20[] memory list = new IERC20[](count);
        uint256 start = (seed >> 8) % _tokens.length;
        for (uint256 k = 0; k < count; ++k) {
            list[k] = _tokens[(start + k) % _tokens.length];
        }
        list = InputHelpers.sortTokens(list);

        uint256[] memory weights = new uint256[](count);
        for (uint256 k = 0; k < count; ++k) {
            weights[k] = k == count - 1 ? FixedPoint.ONE - (FixedPoint.ONE / count) * (count - 1) : FixedPoint.ONE / count;
        }

        PoolRoleAccounts memory roles;
        address index = _weightedFactory.create(
            "Index",
            "IDX",
            _vault.buildTokenConfig(list),
            weights,
            roles,
            bound(seed >> 16, 0.05e16, 10e16),
            address(0),
            false,
            false,
            bytes32(_salt++)
        );

        uint256[] memory amounts = new uint256[](count);
        for (uint256 k = 0; k < count; ++k) {
            amounts[k] = 1_000 * 10 ** IERC20Metadata(address(list[k])).decimals();
        }
        _router.initialize(index, list, amounts, 0, false, "");

        vm.prank(_curator);
        _treasury.allowIndexPool(index);
        indexesCreated++;
    }

    /***************************************************************************
                                    Trading
    ***************************************************************************/

    function swap(uint256 poolSeed, uint256 amountSeed, bool zeroForOne) external tracked {
        address rewardsPool = _pickPool(poolSeed);
        if (_vault.isPoolInitialized(rewardsPool) == false || _vault.isPoolPaused(rewardsPool)) return;

        (IERC20[] memory poolTokens, , uint256[] memory balancesRaw, ) = _vault.getPoolTokenInfo(rewardsPool);
        (uint256 inIdx, uint256 outIdx) = zeroForOne ? (0, 1) : (1, 0);
        uint256 amountIn = bound(amountSeed, _unit(poolTokens[inIdx]) / 100, balancesRaw[inIdx] / 5 + 1);

        // ReClamm refuses trades that would leave its range, and weighted pools over 30% of a balance; that is not what
        // this suite tests.
        try
            _router.swapSingleTokenExactIn(
                rewardsPool,
                poolTokens[inIdx],
                poolTokens[outIdx],
                amountIn,
                0,
                type(uint256).max,
                false,
                ""
            )
        {} catch {}
    }

    /// @dev Moves an index's prices (the setup of a sandwich), or just trades on it.
    function swapIndex(uint256 indexSeed, uint256 pairSeed, uint256 amountSeed) external tracked {
        IERC20[] memory rewardTokens = _rack.getRewardTokens();
        address index = address(rewardTokens[indexSeed % rewardTokens.length]);
        if (_vault.isPoolPaused(index)) return;

        (IERC20[] memory indexTokens, , uint256[] memory balancesRaw, ) = _vault.getPoolTokenInfo(index);
        uint256 i = pairSeed % indexTokens.length;
        uint256 j = (i + 1) % indexTokens.length;
        uint256 amountIn = bound(amountSeed, _unit(indexTokens[i]) / 100, balancesRaw[i] / 4 + 1);

        try
            _router.swapSingleTokenExactIn(index, indexTokens[i], indexTokens[j], amountIn, 0, type(uint256).max, false, "")
        {} catch {}
    }

    function addLiquidity(uint256 poolSeed, uint256 bptSeed) external tracked {
        address rewardsPool = _pickPool(poolSeed);
        if (_vault.isPoolInitialized(rewardsPool) == false || _vault.isPoolPaused(rewardsPool)) return;

        uint256 supply = IERC20(rewardsPool).totalSupply();
        uint256[] memory maxIn = new uint256[](_vault.getPoolTokens(rewardsPool).length);
        for (uint256 k = 0; k < maxIn.length; ++k) maxIn[k] = type(uint128).max;
        try
            _router.addLiquidityProportional(rewardsPool, maxIn, bound(bptSeed, supply / 1e4, supply / 5), false, "")
        {} catch (bytes memory reason) {
            _fail("proportional add failed", reason);
        }
    }

    /// @dev Removes up to all of the handler's BPT: a pool can be left holding little but its locked POL.
    function removeLiquidity(uint256 poolSeed, uint256 bptSeed) external tracked {
        address rewardsPool = _pickPool(poolSeed);
        uint256 held = IERC20(rewardsPool).balanceOf(address(this));
        if (held == 0 || _vault.isPoolPaused(rewardsPool)) return;

        try
            _router.removeLiquidityProportional(
                rewardsPool,
                bound(bptSeed, 1, held),
                new uint256[](_vault.getPoolTokens(rewardsPool).length),
                false,
                ""
            )
        {} catch {
            // The Vault refuses removes that would take a pool below its minimum supply.
        }
    }

    /***************************************************************************
                                    Staking
    ***************************************************************************/

    function stake(uint256 actorSeed, uint256 amountSeed) external tracked {
        address actor = _actors[actorSeed % ACTOR_COUNT];
        // From 1 wei to a whale.
        uint256 amount = bound(amountSeed, 1, 1e26);
        vm.prank(actor);
        _rack.stake(amount);
        staked[actor] += amount;
    }

    function withdraw(uint256 actorSeed, uint256 amountSeed) external tracked {
        address actor = _actors[actorSeed % ACTOR_COUNT];
        uint256 balance = staked[actor];

        // More than the stake must fail.
        vm.prank(actor);
        try _rack.withdraw(balance + 1) {
            _fail("withdrew more than the stake", "");
        } catch {}

        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        uint256 before = _wif.balanceOf(actor);
        vm.prank(actor);
        _rack.withdraw(amount);
        staked[actor] -= amount;
        if (_wif.balanceOf(actor) - before != amount) _fail("withdraw paid the wrong amount", "");
    }

    function claim(uint256 actorSeed, uint256 tokenSeed, bool all) external tracked {
        address actor = _actors[actorSeed % ACTOR_COUNT];
        IERC20[] memory rewardTokens = _rack.getRewardTokens();
        IERC20 token = rewardTokens[tokenSeed % rewardTokens.length];

        uint256 owed = _rack.earned(token, actor);
        uint256 before = token.balanceOf(actor);
        vm.prank(actor);
        if (all) {
            _rack.getReward();
        } else {
            _rack.getReward(token);
        }
        if (token.balanceOf(actor) - before != owed) _fail("claim paid other than earned", "");
    }

    function exit(uint256 actorSeed) external tracked {
        address actor = _actors[actorSeed % ACTOR_COUNT];
        if (staked[actor] == 0) return;
        vm.prank(actor);
        _rack.exit();
        staked[actor] = 0;
    }

    /// @dev Stake and withdraw dust many times in one block, fishing for rounding in the staker's favour.
    function dustCycle(uint256 actorSeed, uint256 amountSeed) external tracked {
        address actor = _actors[actorSeed % ACTOR_COUNT];
        uint256 amount = bound(amountSeed, 1, 1e6);
        vm.startPrank(actor);
        for (uint256 i = 0; i < 5; ++i) {
            _rack.stake(amount);
            _rack.withdraw(amount);
        }
        vm.stopPrank();
    }

    /***************************************************************************
                                    Harvest
    ***************************************************************************/

    /// @dev Half the time waits for the pool's next harvest first; otherwise it may be too soon (and must revert).
    function harvest(uint256 poolSeed, bool waitForIt) external tracked {
        address rewardsPool = _pickPool(poolSeed);
        if (waitForIt) _waitForHarvest(rewardsPool);
        _harvest(rewardsPool);
    }

    /// @dev An index's swap fee manager changes its fee: the add cap must follow, and sandwiches must still not pay.
    function setIndexFee(uint256 indexSeed, uint256 feeSeed) external tracked {
        IERC20[] memory rewardTokens = _rack.getRewardTokens();
        _vault.manualSetStaticSwapFeePercentage(
            address(rewardTokens[indexSeed % rewardTokens.length]),
            bound(feeSeed, 0.05e16, 10e16)
        );
    }

    function warp(uint256 seed) external tracked {
        vm.warp(block.timestamp + bound(seed, 1 minutes, 3 days));
    }

    function togglePause(uint256 seed, bool index) external tracked {
        address target;
        if (index) {
            IERC20[] memory rewardTokens = _rack.getRewardTokens();
            target = address(rewardTokens[seed % rewardTokens.length]);
        } else {
            target = _pickPool(seed);
            if (_vault.isPoolInitialized(target) == false) return;
        }

        if (_vault.isPoolPaused(target)) {
            _vault.manualUnpausePool(target);
        } else {
            _vault.manualPausePool(target);
        }
    }

    /***************************************************************************
                                    Attacks
    ***************************************************************************/

    /**
     * @dev Sells a fee token into the index right before the harvest adds it (making it cheaper), then buys the same
     * amount back. The add is capped at the index's fee, under the fee the round trip pays twice, so it must not
     * profit.
     */
    function sandwichHarvest(uint256 poolSeed, uint256 amountSeed, bool useToken1) external tracked {
        address rewardsPool = _pickPool(poolSeed);
        _waitForHarvest(rewardsPool);
        StakingRewardsTreasury.PoolConfig memory config = _treasury.getPoolConfig(rewardsPool);
        if (_harvestable(rewardsPool, config) == false || config.stakerShare == 0) return;
        // A self-rewarding pool holds no other token to sandwich its own add with (the cap is the same either way).
        if (config.indexPool == rewardsPool) return;
        if (_vault.isPoolPaused(config.indexPool) || _vault.isPoolPaused(rewardsPool)) return;
        if (_rack.totalStaked() == 0) {
            vm.prank(_actors[0]);
            _rack.stake(1_000e18);
            staked[_actors[0]] += 1_000e18;
        }

        IERC20 feeToken = config.tokens[useToken1 ? 1 : 0];
        (IERC20[] memory indexTokens, , uint256[] memory balancesRaw, ) = _vault.getPoolTokenInfo(config.indexPool);
        IERC20 other;
        uint256 feeTokenBalance;
        for (uint256 k = 0; k < indexTokens.length; ++k) {
            if (indexTokens[k] == feeToken) feeTokenBalance = balancesRaw[k];
            else if (_contains(config.tokens, indexTokens[k]) == false) other = indexTokens[k];
        }
        if (address(other) == address(0)) return;

        uint256 amount = bound(amountSeed, _unit(feeToken) / 100, feeTokenBalance / 10 + 1);
        uint256 otherOut;
        try
            _router.swapSingleTokenExactIn(config.indexPool, feeToken, other, amount, 0, type(uint256).max, false, "")
        returns (uint256 out) {
            otherOut = out;
        } catch {
            return;
        }

        _harvest(rewardsPool);

        uint256 otherIn = _router.swapSingleTokenExactOut(
            config.indexPool,
            other,
            feeToken,
            amount,
            type(uint256).max,
            type(uint256).max,
            false,
            ""
        );
        sandwiches++;
        if (otherOut > otherIn) _fail("sandwiching a harvest paid", abi.encode(otherOut - otherIn));
    }

    /// @dev A whale stakes right before a harvest and leaves soon after: it can't earn more than the streams paid out
    /// over the time it stayed.
    function jitHarvest(uint256 poolSeed, uint256 amountSeed, uint256 waitSeed) external tracked {
        address rewardsPool = _pickPool(poolSeed);
        _waitForHarvest(rewardsPool);
        if (_harvestable(rewardsPool, _treasury.getPoolConfig(rewardsPool)) == false) return;

        vm.prank(jitActor);
        _rack.stake(bound(amountSeed, 1e18, 1e28));
        _recordStake();
        _harvest(rewardsPool);

        IERC20[] memory rewardTokens = _rack.getRewardTokens();
        uint256 stay = bound(waitSeed, 1, 1 days);
        uint256[] memory bound_ = new uint256[](rewardTokens.length);
        uint256[] memory before = new uint256[](rewardTokens.length);
        for (uint256 k = 0; k < rewardTokens.length; ++k) {
            StakingRewardsRack.RewardState memory state = _rack.getRewardState(rewardTokens[k]);
            bound_[k] = (state.rewardRate * stay) / 1e18 + 1;
            before[k] = rewardTokens[k].balanceOf(jitActor);
        }

        vm.warp(block.timestamp + stay);
        vm.prank(jitActor);
        _rack.exit();
        jits++;

        for (uint256 k = 0; k < rewardTokens.length; ++k) {
            if (rewardTokens[k].balanceOf(jitActor) - before[k] > bound_[k]) {
                _fail("just-in-time staker beat the stream", abi.encode(rewardTokens[k]));
            }
        }
    }

    /// @dev Tokens sent straight to the treasury must never be booked to a pool, streamed or added.
    function donateToTreasury(uint256 seed, uint256 amountSeed) external tracked {
        IERC20 token;
        if (seed % 3 == 0) {
            // A pool's BPT (the handler holds some of the pools it created).
            token = IERC20(_pickPool(seed >> 8));
        } else {
            token = _tokens[(seed >> 8) % _tokens.length];
        }
        uint256 held = token.balanceOf(address(this));
        if (held == 0) return;
        uint256 amount = bound(amountSeed, 1, held / 100 + 1);
        token.transfer(address(_treasury), amount);
        donatedToTreasury[address(token)] += amount;
    }

    /// @dev Staking tokens or index BPT sent straight to the rack must not change any stake or reward.
    function donateToRack(uint256 seed, uint256 amountSeed) external tracked {
        IERC20 token = _wif;
        if (seed % 2 == 0) {
            IERC20[] memory rewardTokens = _rack.getRewardTokens();
            token = rewardTokens[(seed >> 8) % rewardTokens.length];
        }
        uint256 held = token.balanceOf(address(this));
        if (held == 0) return;
        uint256 amount = bound(amountSeed, 1, held / 100 + 1);
        token.transfer(address(_rack), amount);
        donatedToRack[address(token)] += amount;
    }

    /// @dev Calls only the launcher, the curator, the treasury or the Vault may make.
    function forbiddenCall(uint256 seed) external tracked {
        address rewardsPool = _pickPool(seed >> 8);
        address index = address(_rack.getRewardTokens()[0]);
        uint256 choice = seed % 8;

        bytes memory data;
        address target = address(_treasury);
        if (choice == 0) data = abi.encodeCall(StakingRewardsTreasury.registerPool, (address(this), index, 0, 0));
        else if (choice == 1) data = abi.encodeCall(StakingRewardsTreasury.registerPool, (rewardsPool, index, 0, 90e16));
        else if (choice == 2) data = abi.encodeCall(StakingRewardsTreasury.allowIndexPool, (rewardsPool));
        else if (choice == 3) data = abi.encodeCall(StakingRewardsTreasury.addToIndexHook, (rewardsPool, new uint256[](2)));
        else if (choice == 4) data = abi.encodeCall(StakingRewardsTreasury.addLiquidityHook, (rewardsPool, 1, new uint256[](2)));
        else {
            target = address(_rack);
            if (choice == 5) data = abi.encodeCall(StakingRewardsRack.notifyRewardAmount, (IERC20(index), 0));
            else if (choice == 6) data = abi.encodeCall(StakingRewardsRack.recycle, (IERC20(index)));
            else data = abi.encodeCall(StakingRewardsRack.addRewardToken, (IERC20(address(this))));
        }

        (bool ok, ) = target.call(data);
        if (ok) _fail("a restricted call went through", data);
    }

    /***************************************************************************
                                    Internal
    ***************************************************************************/

    function _harvest(address rewardsPool) internal {
        StakingRewardsTreasury.PoolConfig memory config = _treasury.getPoolConfig(rewardsPool);
        bool tooSoon = config.lastHarvest != 0 && block.timestamp < config.lastHarvest + _treasury.HARVEST_INTERVAL();
        bool anyStaked = _rack.totalStaked() > 0;

        bool initialized = _vault.isPoolInitialized(rewardsPool);

        uint256 tokenCount = config.tokens.length;
        uint256[] memory indexBalances = new uint256[](tokenCount);
        uint256[] memory treasuryBefore = new uint256[](tokenCount);
        if (initialized) {
            (, , uint256[] memory balancesRaw, ) = _vault.getPoolTokenInfo(config.indexPool);
            for (uint256 k = 0; k < tokenCount; ++k) {
                indexBalances[k] = balancesRaw[config.indexOf[k]];
                treasuryBefore[k] = config.tokens[k].balanceOf(address(_treasury));
            }
        }

        vm.recordLogs();
        try _treasury.harvest(rewardsPool) {
            if (initialized == false) _fail("harvested an uninitialized pool", abi.encode(rewardsPool));
            if (tooSoon) _fail("harvested within the interval", abi.encode(rewardsPool));
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            bool expected = (initialized == false && selector == StakingRewardsTreasury.PoolNotInitialized.selector) ||
                (tooSoon && selector == StakingRewardsTreasury.HarvestTooSoon.selector);
            if (expected == false) _fail("harvest reverted", reason);
            vm.getRecordedLogs();
            return;
        }
        harvests++;

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            bytes32 topic = logs[i].topics[0];
            if (logs[i].emitter == address(_treasury) && topic == StakingRewardsTreasury.Harvested.selector) {
                _checkHarvest(rewardsPool, config, logs[i].data, indexBalances, treasuryBefore, anyStaked);
            } else if (logs[i].emitter == address(_rack) && topic == StakingRewardsRack.Recycled.selector) {
                recycled[address(uint160(uint256(logs[i].topics[1])))] += abi.decode(logs[i].data, (uint256));
            } else if (logs[i].emitter == address(_treasury) && topic == StakingRewardsTreasury.AddLiquidityFailed.selector) {
                address target = address(uint160(uint256(logs[i].topics[2])));
                // Only a paused pool or index may refuse an add.
                if (_vault.isPoolPaused(target) == false) _fail("an add failed", logs[i].data);
            }
        }
    }

    function _checkHarvest(
        address rewardsPool,
        StakingRewardsTreasury.PoolConfig memory config,
        bytes memory data,
        uint256[] memory indexBalances,
        uint256[] memory treasuryBefore,
        bool anyStaked
    ) internal {
        (uint256[] memory fees, uint256[] memory toIndex, uint256 streamed, uint256[] memory pol, uint256 bpt) = abi
            .decode(data, (uint256[], uint256[], uint256, uint256[], uint256));
        notified[config.indexPool] += streamed;
        polBpt[rewardsPool] += bpt;

        uint256 toIndexSum;
        for (uint256 k = 0; k < toIndex.length; ++k) toIndexSum += toIndex[k];
        if (anyStaked == false && toIndexSum + streamed > 0) _fail("streamed with nobody staked", data);
        if (config.stakerShare == 0 && toIndexSum > 0) _fail("index add with a zero staker share", data);

        // The fee can't change mid-harvest, so it is the one the harvest read. (A self-rewarding pool's balances were
        // read before its own fees left the Vault, so its cap here is slightly loose.)
        uint256 ratio = _vault.getStaticSwapFeePercentage(config.indexPool);
        if (ratio > _treasury.MAX_INDEX_ADD_RATIO()) ratio = _treasury.MAX_INDEX_ADD_RATIO();
        for (uint256 k = 0; k < toIndex.length; ++k) {
            if (toIndex[k] > indexBalances[k].mulDown(ratio)) _fail("index add over the cap", data);
        }

        // The pool's own tokens: fees in, index and POL adds out, nothing else.
        for (uint256 k = 0; k < config.tokens.length; ++k) {
            if (treasuryBefore[k] + fees[k] != toIndex[k] + pol[k] + config.tokens[k].balanceOf(address(_treasury))) {
                _fail("harvest did not conserve tokens", data);
            }
        }
    }

    function _waitForHarvest(address rewardsPool) internal {
        uint256 lastHarvest = _treasury.getPoolConfig(rewardsPool).lastHarvest;
        uint256 next = lastHarvest + _treasury.HARVEST_INTERVAL();
        if (lastHarvest != 0 && block.timestamp < next) vm.warp(next);
    }

    function _recordStake() internal {
        if (_rack.totalStaked() > maxTotalStaked) maxTotalStaked = _rack.totalStaked();
    }

    function _harvestable(address rewardsPool, StakingRewardsTreasury.PoolConfig memory config) internal view returns (bool) {
        return
            _vault.isPoolInitialized(rewardsPool) &&
            (config.lastHarvest == 0 || block.timestamp >= config.lastHarvest + _treasury.HARVEST_INTERVAL());
    }

    // A ReClamm pool at its target price; a weighted pool at whatever prices the random amounts make.
    function _initialize(address rewardsPool, IERC20 referenceToken, uint256 amountSeed) internal {
        IERC20[] memory poolTokens = _vault.getPoolTokens(rewardsPool);
        uint256[] memory amounts;
        if (isWeighted[rewardsPool]) {
            amounts = new uint256[](poolTokens.length);
            for (uint256 k = 0; k < poolTokens.length; ++k) {
                uint256 seed = uint256(keccak256(abi.encode(amountSeed, k)));
                amounts[k] = bound(seed, 1_000, 100_000) * _unit(poolTokens[k]);
            }
        } else {
            uint256 amount = bound(amountSeed, 1_000, 100_000) * _unit(referenceToken);
            amounts = IReClammPool(rewardsPool).computeInitialBalancesRaw(referenceToken, amount);
        }
        try _router.initialize(rewardsPool, poolTokens, amounts, 0, false, "") {
            if (_feeController.getPoolCreatorSwapFeePercentage(rewardsPool) != creatorFee[rewardsPool]) {
                _fail("creator fee changed on initialize", "");
            }
        } catch (bytes memory reason) {
            _fail("initialize failed", reason);
        }
    }

    function _contains(IERC20[] memory list, IERC20 token) internal pure returns (bool) {
        for (uint256 k = 0; k < list.length; ++k) {
            if (list[k] == token) return true;
        }
        return false;
    }

    function _pickPool(uint256 seed) internal view returns (address) {
        return _pools[seed % _pools.length];
    }

    function _unit(IERC20 token) internal view returns (uint256) {
        return 10 ** IERC20Metadata(address(token)).decimals();
    }

    function _approveRouter(IERC20 token) internal {
        token.approve(address(_permit2), type(uint256).max);
        token.approve(address(_router), type(uint256).max);
        _permit2.approve(address(token), address(_router), type(uint160).max, type(uint48).max);
    }

    function _fail(string memory message, bytes memory data) internal {
        if (bytes(failure).length == 0) {
            failure = message;
            failureData = data;
        }
    }
}

/**
 * @notice Stateful invariants of the staking rewards contracts (foundry.toml: [invariant]), with a 20% protocol swap fee so fees are
 * split three ways. Each one is an accounting identity that holds after every step, whatever the order.
 */
contract StakingRewardsInvariantsTest is BaseStakingRewardsTest {
    StakingRewardsHandler internal handler;

    function setUp() public override {
        vaultMockInitialProtocolSwapFeePercentage = 20e16;
        super.setUp();

        IERC20[] memory list = new IERC20[](6);
        (list[0], list[1], list[2], list[3], list[4], list[5]) = (wif, usdc, usdt, pair, wsteth, usdc6Decimals);
        address[] memory pools = new address[](2);
        (pools[0], pools[1]) = (pool, poolB);

        handler = new StakingRewardsHandler(
            StakingRewardsHandler.Env({
                vault: vault,
                router: router,
                permit2: permit2,
                feeController: feeController,
                launcher: launcher,
                weightedFactory: weightedFactory,
                curator: admin,
                wif: wif,
                tokens: list,
                pools: pools
            })
        );
        for (uint256 i = 0; i < list.length; ++i) {
            deal(address(list[i]), address(handler), 1e12 * 10 ** IERC20Metadata(address(list[i])).decimals());
        }

        bytes4[] memory selectors = new bytes4[](21);
        selectors[0] = StakingRewardsHandler.createPool.selector;
        selectors[1] = StakingRewardsHandler.initializePending.selector;
        selectors[2] = StakingRewardsHandler.createIndex.selector;
        selectors[3] = StakingRewardsHandler.swap.selector;
        selectors[4] = StakingRewardsHandler.donateToRack.selector;
        selectors[5] = StakingRewardsHandler.swapIndex.selector;
        selectors[6] = StakingRewardsHandler.addLiquidity.selector;
        selectors[7] = StakingRewardsHandler.removeLiquidity.selector;
        selectors[8] = StakingRewardsHandler.stake.selector;
        selectors[9] = StakingRewardsHandler.withdraw.selector;
        selectors[10] = StakingRewardsHandler.claim.selector;
        selectors[11] = StakingRewardsHandler.exit.selector;
        selectors[12] = StakingRewardsHandler.dustCycle.selector;
        selectors[13] = StakingRewardsHandler.harvest.selector;
        selectors[14] = StakingRewardsHandler.warp.selector;
        selectors[15] = StakingRewardsHandler.togglePause.selector;
        selectors[16] = StakingRewardsHandler.sandwichHarvest.selector;
        selectors[17] = StakingRewardsHandler.jitHarvest.selector;
        selectors[18] = StakingRewardsHandler.donateToTreasury.selector;
        selectors[19] = StakingRewardsHandler.forbiddenCall.selector;
        selectors[20] = StakingRewardsHandler.setIndexFee.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// @dev Every check the handler makes along the way (see its actions).
    function invariant_noFailures() public view {
        if (bytes(handler.failure()).length > 0) console2.logBytes(handler.failureData());
        assertEq(handler.failure(), "", "handler check failed");
    }

    /// @dev The treasury holds exactly what the pools' ledgers book, plus what was donated: no pool's tokens are spent
    /// for another, and nothing is minted or lost.
    function invariant_treasuryMatchesLedgers() public view {
        IERC20[] memory list = handler.getTokens();
        address[] memory pools = handler.getPools();
        for (uint256 t = 0; t < list.length; ++t) {
            uint256 booked = handler.donatedToTreasury(address(list[t]));
            for (uint256 p = 0; p < pools.length; ++p) {
                StakingRewardsTreasury.PoolConfig memory config = treasury.getPoolConfig(pools[p]);
                StakingRewardsTreasury.Ledger memory ledger = treasury.getLedger(pools[p]);
                for (uint256 k = 0; k < config.tokens.length; ++k) {
                    if (config.tokens[k] == list[t]) booked += ledger.reserved[k] + ledger.carry[k];
                }
            }
            assertEq(list[t].balanceOf(address(treasury)), booked, "treasury balance != ledgers + donations");
        }
    }

    /// @dev Index BPT only passes through the treasury: all it holds is what waits to be streamed again (and donations,
    /// and a self-rewarding pool's own POL).
    function invariant_treasuryIndexBpt() public view {
        IERC20[] memory rewardTokens = rack.getRewardTokens();
        for (uint256 i = 0; i < rewardTokens.length; ++i) {
            address index = address(rewardTokens[i]);
            assertEq(
                rewardTokens[i].balanceOf(address(treasury)),
                treasury.recycledBpt(index) + handler.donatedToTreasury(index) + treasury.protocolOwnedBpt(index),
                "stray index BPT in the treasury"
            );
        }
    }

    /// @dev The POL is exactly what the harvests added, and the treasury holds it (with any BPT waiting to be
    /// streamed again, and donations): it never leaves.
    function invariant_polLocked() public view {
        address[] memory pools = handler.getPools();
        for (uint256 p = 0; p < pools.length; ++p) {
            assertEq(treasury.protocolOwnedBpt(pools[p]), handler.polBpt(pools[p]), "POL booked != added");
            assertEq(
                IERC20(pools[p]).balanceOf(address(treasury)),
                treasury.protocolOwnedBpt(pools[p]) + treasury.recycledBpt(pools[p]) + handler.donatedToTreasury(pools[p]),
                "POL moved"
            );
        }
    }

    /// @dev Every staked token is backed and accounted to its staker.
    function invariant_stakesBacked() public view {
        address[] memory stakers = handler.getStakers();
        uint256 sum;
        for (uint256 i = 0; i < stakers.length; ++i) {
            uint256 balance = rack.balanceOf(stakers[i]);
            assertEq(balance, handler.staked(stakers[i]), "stake balance != staked");
            sum += balance;
        }
        assertEq(rack.totalStaked(), sum, "totalStaked != sum of stakes");
        assertEq(
            wif.balanceOf(address(rack)),
            rack.totalStaked() + handler.donatedToRack(address(wif)),
            "rack staking token != stakes + donations"
        );
    }

    /**
     * @dev For each reward token: everything streamed in was either paid out, sent back to the treasury, or is still
     * owed (`rewardReserve`); the rack holds exactly that (plus donations); and what stakers can claim plus what is
     * unallocated never exceeds it.
     */
    function invariant_rewardsAccounted() public view {
        IERC20[] memory rewardTokens = rack.getRewardTokens();
        address[] memory stakers = handler.getStakers();
        for (uint256 i = 0; i < rewardTokens.length; ++i) {
            IERC20 token = rewardTokens[i];
            StakingRewardsRack.RewardState memory state = rack.getRewardState(token);

            uint256 claimed;
            uint256 claimable;
            for (uint256 s = 0; s < stakers.length; ++s) {
                claimed += token.balanceOf(stakers[s]);
                claimable += rack.earned(token, stakers[s]);
            }

            assertEq(
                state.rewardReserve + claimed + handler.recycled(address(token)),
                handler.notified(address(token)),
                "streamed != reserve + claimed + recycled"
            );
            assertEq(
                token.balanceOf(address(rack)),
                state.rewardReserve + handler.donatedToRack(address(token)),
                "rack balance != reserve + donations"
            );
            assertLe(claimable + state.unallocated, state.rewardReserve, "owed more than the reserve");
        }
    }

    /// @dev Each pool's creator fee is what it was launched with, initialized or not, in the fee controller and in the
    /// Vault's aggregate fee; a pool keeps no staker reserve if its staker share is zero.
    function invariant_poolConfig() public view {
        address[] memory pools = handler.getPools();
        for (uint256 p = 0; p < pools.length; ++p) {
            StakingRewardsTreasury.PoolConfig memory config = treasury.getPoolConfig(pools[p]);
            assertEq(feeController.getPoolCreatorSwapFeePercentage(pools[p]), handler.creatorFee(pools[p]), "creator fee");
            (uint256 protocolFee, ) = feeController.getPoolProtocolSwapFeeInfo(pools[p]);
            assertEq(
                vault.getPoolConfig(pools[p]).aggregateSwapFeePercentage,
                feeController.computeAggregateFeePercentage(protocolFee, handler.creatorFee(pools[p])),
                "aggregate fee"
            );
            if (config.stakerShare == 0) {
                StakingRewardsTreasury.Ledger memory ledger = treasury.getLedger(pools[p]);
                for (uint256 k = 0; k < ledger.reserved.length; ++k) {
                    assertEq(ledger.reserved[k], 0, "reserve with a zero staker share");
                }
            }
        }
    }

    /**
     * @dev At the end of each run, every stream finishes and everyone leaves: each staker gets their whole stake back
     * and every reward they earned, and the rack keeps only what was unallocated, donated, or rounding dust.
     */
    function afterInvariant() public {
        console2.log("harvests", handler.harvests(), "sandwiches", handler.sandwiches());
        console2.log("jits", handler.jits(), "pools created", handler.poolsCreated());
        console2.log("indexes created", handler.indexesCreated(), "self-rewarding", handler.selfRewardingCreated());

        vm.warp(block.timestamp + rack.REWARD_DURATION() + 1);
        address[] memory stakers = handler.getStakers();
        IERC20[] memory rewardTokens = rack.getRewardTokens();

        for (uint256 s = 0; s < stakers.length; ++s) {
            uint256 stake = rack.balanceOf(stakers[s]);
            uint256 before = wif.balanceOf(stakers[s]);
            vm.startPrank(stakers[s]);
            if (stake > 0) rack.withdraw(stake);
            rack.getReward();
            vm.stopPrank();
            assertEq(wif.balanceOf(stakers[s]) - before, stake, "stake not returned in full");
            for (uint256 i = 0; i < rewardTokens.length; ++i) {
                assertEq(rack.earned(rewardTokens[i], stakers[s]), 0, "reward left unclaimed");
            }
        }

        assertEq(rack.totalStaked(), 0, "stake left");
        assertEq(wif.balanceOf(address(rack)), handler.donatedToRack(address(wif)), "staking tokens left");

        // `rewardPerToken` rounds down on each update; each staker loses under `balance / 1e18` wei per update.
        uint256 dust = (handler.calls() + stakers.length + 1) * (handler.maxTotalStaked() / 1e18 + 1);
        for (uint256 i = 0; i < rewardTokens.length; ++i) {
            StakingRewardsRack.RewardState memory state = rack.getRewardState(rewardTokens[i]);
            assertLe(state.rewardReserve - state.unallocated, dust, "rewards stuck in the rack beyond rounding");
        }
    }
}
