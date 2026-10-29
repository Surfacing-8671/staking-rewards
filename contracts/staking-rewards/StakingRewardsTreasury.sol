// SPDX-License-Identifier: GPL-3.0-or-later
// solhint-disable not-rely-on-time

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IProtocolFeeController } from "@bush.fi/v3-interfaces/contracts/vault/IProtocolFeeController.sol";
import { IVault } from "@bush.fi/v3-interfaces/contracts/vault/IVault.sol";
import { AddLiquidityKind, AddLiquidityParams, PoolData } from "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { ReentrancyGuardTransient } from "@bush.fi/v3-solidity-utils/contracts/openzeppelin/ReentrancyGuardTransient.sol";

import { StakingRewardsRack } from "./StakingRewardsRack.sol";

/**
 * @notice The one treasury behind every staking rewards pool of a launcher: the pool creator of each. On `harvest(pool)`, it
 * turns `stakerShare` of that pool's new fees into BPT of the pool's index pool (e.g., WIF, WETH and RWA tokens),
 * streamed to the stakers of the rack, and adds the rest to that pool as protocol-owned liquidity (POL).
 * @dev The rack stakes one token (e.g., $WIF), which the curator sets once after deployment, and pays every approved index pool's BPT as a separate reward stream.
 *
 * Index pools are approved by the `curator`, up to the rack's `MAX_REWARD_TOKENS`; each becomes a reward token. A
 * staking rewards pool can only be launched with an approved index pool that holds all of its tokens, so the curator also
 * decides which tokens can join.
 *
 * A self-rewarding pool is its own index: its staker share goes back into it (one-sided and capped, like any index
 * add), and its own BPT is the reward. The launcher only creates one for the curator, and registering it approves it as
 * an index pool, so other staking rewards pools holding its tokens may feed it too.
 *
 * Only the launcher registers pools, once each, right after creating them (with this treasury as pool creator); the
 * treasury then sets the pool's creator fee, and never changes it. Staking rewards pools are pools of any type with
 * proportional liquidity (two-token ReClamm, or weighted with up to the Vault's maximum tokens).
 *
 * Pools never touch each other's tokens: each has its own ledger of tokens reserved for stakers (`reserved`) and left
 * over for POL (`carry`), and the treasury never acts on its total balances. Fees are measured as the balance change
 * across that pool's own fee withdrawal. Each pool is harvested on its own, once per `HARVEST_INTERVAL`, by anyone.
 *
 * The POL is each pool's BPT added by its harvests (`protocolOwnedBpt`), and no function moves it out: that liquidity
 * is locked for good. The POL add is proportional, so it has no price impact and can't be sandwiched. Whatever can't be
 * paired carries over in the pool's ledger: with more than two tokens, the least traded one sets the pace.
 *
 * The index add is one-sided (only the staking rewards pool's tokens, in whatever amounts the fees came in), so the index's own
 * trading rebalances it into its other tokens. That can be sandwiched: someone moves the index's price of the fee tokens first, so the add
 * buys less BPT. To bound that, each harvest adds at most the index's static swap fee (and at most
 * `MAX_INDEX_ADD_RATIO`) of the index's balance of each token; the rest stays reserved and goes in with later harvests.
 * The add then moves the index's price by about its fee at most, while moving the price and back costs the attacker
 * that fee twice, so a sandwich doesn't pay whatever the index's fee. A dynamic fee hook that charges less than the
 * static fee weakens this.
 *
 * With nobody staked, all new fees go to POL, and BPT recycled from the rack waits (per index pool) for a harvest with
 * stakers. A failed add (e.g., a pool paused) never blocks the rest of the harvest; the tokens carry over.
 */
contract StakingRewardsTreasury is ReentrancyGuardTransient {
    using FixedPoint for uint256;
    using SafeERC20 for IERC20;

    struct PoolConfig {
        // The pool's tokens, in Vault order.
        IERC20[] tokens;
        // The pool itself, if it is self-rewarding.
        address indexPool;
        // The index pool's token count, and where each pool token sits in it.
        uint8 indexTokenCount;
        uint8[] indexOf;
        uint64 lastHarvest;
        uint256 stakerShare;
    }

    struct Ledger {
        // Fee tokens set aside for stakers that have not gone into the index yet (capped, unpaired or failed adds).
        uint256[] reserved;
        // Fee tokens left over for POL (not yet paired).
        uint256[] carry;
    }

    struct HarvestResult {
        uint256[] fees;
        uint256[] toIndex;
        uint256 indexBptStreamed;
        uint256[] pol;
        uint256 polBpt;
    }

    uint256 public constant HARVEST_INTERVAL = 1 days;

    // The most each harvest adds to an index, as a share of the index's balance of each token. The index's swap fee
    // lowers it further (see `_addToIndex`).
    uint256 public constant MAX_INDEX_ADD_RATIO = 1e16; // 1%

    // Smaller index adds are skipped (the Vault refuses amounts below its minimum trade amount, and one token's dust
    // must not block the others' add).
    uint256 public constant MIN_INDEX_ADD_SCALED18 = 1e9;

    // Index adds of a token below this share of the index's balance of it are skipped too: that small, the rounding of
    // the index's invariant can outweigh the add, and the Vault's unbalanced add maths underflows.
    uint256 public constant MIN_INDEX_ADD_RATIO = 1e8; // 1e-10, 18-decimal FP

    // The POL add asks for slightly less BPT than the balances could buy, so the Vault's rounding up of the amounts in
    // never exceeds them.
    uint256 internal constant _POL_SAFETY_MARGIN = 1e12; // 1 ppm, 18-decimal FP

    // Below this, a POL add is skipped (the Vault refuses amounts below its minimum trade amount anyway).
    uint256 public constant MIN_POL_BPT = 1e9;

    IVault public immutable vault;
    IProtocolFeeController public immutable feeController;
    address public immutable launcher;
    address public immutable curator;
    StakingRewardsRack public immutable rack;

    mapping(address indexPool => bool approved) public isIndexPool;

    // Index BPT the rack returned (streamed while nobody was staked), waiting to be streamed again.
    mapping(address indexPool => uint256 amount) public recycledBpt;

    /// @notice A pool's BPT that its harvests added as POL, held by the treasury. It can never leave.
    mapping(address pool => uint256 amount) public protocolOwnedBpt;

    mapping(address pool => PoolConfig config) internal _pools;
    mapping(address pool => Ledger ledger) internal _ledgers;

    event IndexPoolAllowed(address indexed indexPool);

    event PoolRegistered(address indexed pool, address indexed indexPool, uint256 stakerShare);

    /// @notice The amounts are by pool token, in Vault order.
    event Harvested(
        address indexed pool,
        uint256[] fees,
        uint256[] toIndex,
        uint256 indexBptStreamed,
        uint256[] pol,
        uint256 polBpt
    );

    /// @notice An add failed; the tokens stay in the pool's ledger for the next harvest.
    event AddLiquidityFailed(address indexed pool, address indexed target, bytes reason);

    /// @notice Only the launcher can register pools.
    error SenderIsNotLauncher();

    /// @notice Only the curator can set the staking token and approve index pools.
    error SenderIsNotCurator();

    /// @notice Only the Vault can call back into the treasury.
    error SenderIsNotVault();

    /// @notice The pool was already registered.
    error AlreadyRegistered(address pool);

    /// @notice The pool is not a registered staking rewards pool.
    error UnknownPool(address pool);

    /// @notice The pool is not initialized yet (nothing to harvest).
    error PoolNotInitialized(address pool);

    /// @notice The last harvest of this pool was less than `HARVEST_INTERVAL` ago.
    error HarvestTooSoon(uint256 nextHarvest);

    /// @notice The index pool was not approved by the curator.
    error IndexPoolNotAllowed(address indexPool);

    /// @notice The index pool was already approved.
    error IndexPoolAlreadyAllowed(address indexPool);

    /// @notice The index pool does not hold this staking rewards pool token.
    error IndexPoolMissingToken(IERC20 token);

    /// @notice The index pool does not accept unbalanced liquidity, so fees can't go in one-sided.
    error IndexPoolNeedsUnbalancedLiquidity();

    /**
     * @param vault_ The Bush Vault
     * @param curator_ The account that sets the staking token and approves index pools
     */
    constructor(IVault vault_, address curator_) {
        vault = vault_;
        feeController = vault_.getProtocolFeeController();
        launcher = msg.sender;
        curator = curator_;
        rack = new StakingRewardsRack();
    }

    /********************************************************
                            Views
    ********************************************************/

    function getPoolConfig(address pool) external view returns (PoolConfig memory) {
        return _pools[pool];
    }

    function getLedger(address pool) external view returns (Ledger memory) {
        return _ledgers[pool];
    }

    /// @notice Whether the pool is its own index: its staker share goes back into it, and its own BPT is the reward.
    function isSelfRewarding(address pool) public view returns (bool) {
        return _pools[pool].indexPool == pool && pool != address(0);
    }

    /********************************************************
                    Curator and launcher functions
    ********************************************************/

    /**
     * @notice Sets the token the rack stakes (e.g., $WIF). Nobody can stake until then.
     * @dev Once only, and it can't be an approved index pool (the rack refuses a reward token).
     */
    function setStakingToken(IERC20 token) external {
        require(msg.sender == curator, SenderIsNotCurator());
        rack.setStakingToken(token);
    }

    /**
     * @notice Approves an index pool: staking rewards pools may use it, and its BPT becomes a reward token of the rack.
     * @dev It can never be removed, and the rack takes at most `MAX_REWARD_TOKENS`.
     */
    function allowIndexPool(address indexPool) external {
        require(msg.sender == curator, SenderIsNotCurator());
        _allowIndexPool(indexPool);
    }

    /**
     * @notice Registers a staking rewards pool the launcher just created, and sets its creator fee.
     * @dev The pool must be registered with the Vault, with this treasury as pool creator (or the fee controller
     * refuses the fee). Setting the fee before initialization is safe: `initialize` keeps the pool config it loads.
     *
     * If `indexPool` is the pool itself, it is self-rewarding, and this approves it as an index pool; the launcher
     * only does that for the curator.
     * @param pool The staking rewards pool
     * @param indexPool An approved index pool holding all of the pool's tokens, or the pool itself
     * @param stakerShare The share of each harvest's new fees that goes to stakers, 18-decimal FP
     * @param creatorFeePercentage The pool creator share of swap fees
     */
    function registerPool(
        address pool,
        address indexPool,
        uint256 stakerShare,
        uint256 creatorFeePercentage
    ) external {
        require(msg.sender == launcher, SenderIsNotLauncher());
        require(_pools[pool].tokens.length == 0, AlreadyRegistered(pool));

        if (indexPool == pool) {
            _allowIndexPool(pool);
        } else {
            require(isIndexPool[indexPool], IndexPoolNotAllowed(indexPool));
        }

        IERC20[] memory tokens = vault.getPoolTokens(pool);
        IERC20[] memory indexTokens = vault.getPoolTokens(indexPool);
        uint8[] memory indexOf = new uint8[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            indexOf[i] = _find(indexTokens, tokens[i]);
        }

        _pools[pool] = PoolConfig({
            tokens: tokens,
            indexPool: indexPool,
            indexTokenCount: uint8(indexTokens.length),
            indexOf: indexOf,
            lastHarvest: 0,
            stakerShare: stakerShare
        });

        Ledger storage ledger = _ledgers[pool];
        ledger.reserved = new uint256[](tokens.length);
        ledger.carry = new uint256[](tokens.length);

        feeController.setPoolCreatorSwapFeePercentage(pool, creatorFeePercentage);

        emit PoolRegistered(pool, indexPool, stakerShare);
    }

    /********************************************************
                            Harvest
    ********************************************************/

    /**
     * @notice Collects a pool's creator fees, adds the staker share to its index pool and streams the index BPT to the
     * rack, and adds the rest to the pool as POL.
     */
    function harvest(address pool) external nonReentrant {
        PoolConfig storage config = _pools[pool];
        uint256 tokenCount = config.tokens.length;
        require(tokenCount > 0, UnknownPool(pool));
        require(vault.isPoolInitialized(pool), PoolNotInitialized(pool));

        uint256 nextHarvest = config.lastHarvest + HARVEST_INTERVAL;
        require(config.lastHarvest == 0 || block.timestamp >= nextHarvest, HarvestTooSoon(nextHarvest));
        config.lastHarvest = uint64(block.timestamp);

        HarvestResult memory result;
        result.fees = _collectFees(pool, config.tokens);
        result.toIndex = new uint256[](tokenCount);

        Ledger storage ledger = _ledgers[pool];
        address indexPool = config.indexPool;
        recycledBpt[indexPool] += rack.recycle(IERC20(indexPool));

        if (rack.totalStaked() > 0) {
            for (uint256 i = 0; i < tokenCount; ++i) {
                uint256 toStakers = result.fees[i].mulDown(config.stakerShare);
                ledger.reserved[i] += toStakers;
                ledger.carry[i] += result.fees[i] - toStakers;
            }

            uint256 bptOut;
            (result.toIndex, bptOut) = _addToIndex(pool, config, ledger);

            // New BPT, and any recycled for this index.
            result.indexBptStreamed = bptOut + recycledBpt[indexPool];
            if (result.indexBptStreamed > 0) {
                recycledBpt[indexPool] = 0;
                IERC20(indexPool).safeTransfer(address(rack), result.indexBptStreamed);
                rack.notifyRewardAmount(IERC20(indexPool), result.indexBptStreamed);
            }
        } else {
            for (uint256 i = 0; i < tokenCount; ++i) {
                ledger.carry[i] += result.fees[i];
            }
        }

        (result.pol, result.polBpt) = _addProtocolOwnedLiquidity(pool, ledger.carry);
        protocolOwnedBpt[pool] += result.polBpt;

        emit Harvested(pool, result.fees, result.toIndex, result.indexBptStreamed, result.pol, result.polBpt);
    }

    /// @notice The Vault callback of an index add: adds `exactAmountsIn` unbalanced to `pool`'s index pool.
    function addToIndexHook(address pool, uint256[] memory exactAmountsIn) external returns (uint256 bptAmountOut) {
        require(msg.sender == address(vault), SenderIsNotVault());
        PoolConfig storage config = _pools[pool];

        uint256[] memory amountsIn;
        (amountsIn, bptAmountOut, ) = vault.addLiquidity(
            AddLiquidityParams({
                pool: config.indexPool,
                to: address(this),
                maxAmountsIn: exactAmountsIn,
                minBptAmountOut: 1,
                kind: AddLiquidityKind.UNBALANCED,
                userData: ""
            })
        );

        for (uint256 i = 0; i < config.tokens.length; ++i) {
            _settle(config.tokens[i], amountsIn[config.indexOf[i]]);
        }
    }

    /// @notice The Vault callback of a POL add: adds `exactBptOut` of `pool` proportionally.
    function addLiquidityHook(
        address pool,
        uint256 exactBptOut,
        uint256[] memory maxAmountsIn
    ) external returns (uint256[] memory amountsIn) {
        require(msg.sender == address(vault), SenderIsNotVault());
        PoolConfig storage config = _pools[pool];

        (amountsIn, , ) = vault.addLiquidity(
            AddLiquidityParams({
                pool: pool,
                to: address(this),
                maxAmountsIn: maxAmountsIn,
                minBptAmountOut: exactBptOut,
                kind: AddLiquidityKind.PROPORTIONAL,
                userData: ""
            })
        );

        for (uint256 i = 0; i < amountsIn.length; ++i) {
            _settle(config.tokens[i], amountsIn[i]);
        }
    }

    /********************************************************
                            Internal
    ********************************************************/

    function _allowIndexPool(address indexPool) internal {
        require(isIndexPool[indexPool] == false, IndexPoolAlreadyAllowed(indexPool));
        // Reverts if the index pool is not registered.
        vault.getPoolTokens(indexPool);
        require(
            vault.getPoolConfig(indexPool).liquidityManagement.disableUnbalancedLiquidity == false,
            IndexPoolNeedsUnbalancedLiquidity()
        );

        isIndexPool[indexPool] = true;
        rack.addRewardToken(IERC20(indexPool));

        emit IndexPoolAllowed(indexPool);
    }

    // The pool's creator fees, measured as the balance change across its own withdrawal.
    function _collectFees(address pool, IERC20[] storage tokens) internal returns (uint256[] memory fees) {
        uint256 tokenCount = tokens.length;
        fees = new uint256[](tokenCount);
        for (uint256 i = 0; i < tokenCount; ++i) {
            fees[i] = tokens[i].balanceOf(address(this));
        }

        feeController.collectAggregateFees(pool);
        feeController.withdrawPoolCreatorFees(pool, address(this));

        for (uint256 i = 0; i < tokenCount; ++i) {
            fees[i] = tokens[i].balanceOf(address(this)) - fees[i];
        }
    }

    // Adds as much of the pool's reserve as the cap allows to its index pool (the pool itself if self-rewarding),
    // one-sided.
    function _addToIndex(
        address pool,
        PoolConfig storage config,
        Ledger storage ledger
    ) internal returns (uint256[] memory amounts, uint256 bptOut) {
        uint256 tokenCount = config.tokens.length;
        amounts = new uint256[](tokenCount);

        address indexPool = config.indexPool;
        if (vault.isPoolInitialized(indexPool) == false) {
            return (amounts, 0);
        }

        // Read at each harvest, so the cap follows the index's fee if its swap fee manager changes it.
        uint256 addRatio = vault.getStaticSwapFeePercentage(indexPool);
        if (addRatio > MAX_INDEX_ADD_RATIO) {
            addRatio = MAX_INDEX_ADD_RATIO;
        }

        PoolData memory indexData = vault.getPoolData(indexPool);
        uint256[] memory amountsIn = new uint256[](config.indexTokenCount);
        bool any;
        for (uint256 i = 0; i < tokenCount; ++i) {
            uint256 index = config.indexOf[i];
            amounts[i] = _cappedIndexAmount(ledger.reserved[i], indexData, index, addRatio);
            amountsIn[index] = amounts[i];
            any = any || amounts[i] > 0;
        }
        if (any == false) {
            return (amounts, 0);
        }

        try vault.unlock(abi.encodeCall(StakingRewardsTreasury.addToIndexHook, (pool, amountsIn))) returns (
            bytes memory result
        ) {
            bptOut = abi.decode(result, (uint256));
            for (uint256 i = 0; i < tokenCount; ++i) {
                ledger.reserved[i] -= amounts[i];
            }
        } catch (bytes memory reason) {
            emit AddLiquidityFailed(pool, indexPool, reason);
            return (new uint256[](tokenCount), 0);
        }
    }

    function _cappedIndexAmount(
        uint256 reserved,
        PoolData memory indexData,
        uint256 index,
        uint256 addRatio
    ) internal pure returns (uint256 amount) {
        uint256 balance = indexData.balancesRaw[index];
        uint256 cap = balance.mulDown(addRatio);
        amount = reserved < cap ? reserved : cap;
        if (
            amount * indexData.decimalScalingFactors[index] < MIN_INDEX_ADD_SCALED18 ||
            amount < balance.mulDown(MIN_INDEX_ADD_RATIO)
        ) {
            amount = 0;
        }
    }

    // The largest proportional add the pool's carry-over (`available`) pays for; takes what it spends out of it.
    function _addProtocolOwnedLiquidity(
        address pool,
        uint256[] storage available
    ) internal returns (uint256[] memory amountsIn, uint256 bptOut) {
        (, , uint256[] memory balancesRaw, ) = vault.getPoolTokenInfo(pool);
        uint256 totalSupply = vault.totalSupply(pool);
        uint256 tokenCount = balancesRaw.length;
        uint256[] memory maxAmountsIn = available;

        bptOut = type(uint256).max;
        for (uint256 i = 0; i < tokenCount; ++i) {
            uint256 bpt = (maxAmountsIn[i] * totalSupply) / balancesRaw[i];
            if (bpt < bptOut) {
                bptOut = bpt;
            }
        }
        bptOut = bptOut.mulDown(FixedPoint.ONE - _POL_SAFETY_MARGIN);

        if (bptOut < MIN_POL_BPT) {
            return (new uint256[](tokenCount), 0);
        }

        try vault.unlock(abi.encodeCall(StakingRewardsTreasury.addLiquidityHook, (pool, bptOut, maxAmountsIn))) returns (
            bytes memory result
        ) {
            amountsIn = abi.decode(result, (uint256[]));
            for (uint256 i = 0; i < tokenCount; ++i) {
                available[i] -= amountsIn[i];
            }
        } catch (bytes memory reason) {
            emit AddLiquidityFailed(pool, pool, reason);
            return (new uint256[](tokenCount), 0);
        }
    }

    function _settle(IERC20 token, uint256 amount) internal {
        if (amount > 0) {
            token.safeTransfer(address(vault), amount);
            vault.settle(token, amount);
        }
    }

    function _find(IERC20[] memory tokens, IERC20 token) internal pure returns (uint8) {
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (tokens[i] == token) {
                return uint8(i);
            }
        }
        revert IndexPoolMissingToken(token);
    }
}
