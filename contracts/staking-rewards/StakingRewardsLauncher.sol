// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IRateProvider } from "@bush.fi/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IVault } from "@bush.fi/v3-interfaces/contracts/vault/IVault.sol";
import { TokenConfig, TokenType, PoolRoleAccounts } from "@bush.fi/v3-interfaces/contracts/vault/VaultTypes.sol";

import { InputHelpers } from "@bush.fi/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { FixedPoint } from "@bush.fi/v3-solidity-utils/contracts/math/FixedPoint.sol";

import { ReClammPriceParams } from "../reclamm/lib/ReClammPoolFactoryLib.sol";
import { ReClammPoolFactory } from "../reclamm/ReClammPoolFactory.sol";
import { WeightedPoolFactory } from "../weighted/WeightedPoolFactory.sol";
import { StakingRewardsTreasury } from "./StakingRewardsTreasury.sol";

/**
 * @notice The staking rewards settings every pool is launched with.
 * @param swapFeePercentage The pool's swap fee, 18-decimal FP (bounded by the pool type)
 * @param creatorFeePercentage The share of swap fees (after the protocol's) that goes to the treasury
 * @param stakerShare The share of each harvest that goes to stakers (as index BPT); the rest becomes protocol-owned
 * liquidity in the pool
 */
struct StakingRewardsParams {
    string name;
    string symbol;
    uint256 swapFeePercentage;
    uint256 creatorFeePercentage;
    uint256 stakerShare;
}

/**
 * @notice ReClamm settings of a staking rewards pool.
 * @param baseToken One pool token (e.g., $WIF); the prices are given for it
 * @param quoteToken The other pool token (e.g., WETH); the prices are given in it
 * @param initialMinPrice The initial minimum price of the base token in the quote token, 18-decimal FP
 * @param initialMaxPrice The initial maximum price of the base token in the quote token, 18-decimal FP
 * @param initialTargetPrice The initial price of the base token in the quote token, 18-decimal FP
 * @param dailyPriceShiftExponent How fast the price range follows the market when out of range (see ReClammPool)
 * @param centerednessMargin How far the price can be from the center before the range starts to move
 */
struct StakingRewardsReClammParams {
    IERC20 baseToken;
    IERC20 quoteToken;
    uint256 initialMinPrice;
    uint256 initialMaxPrice;
    uint256 initialTargetPrice;
    uint256 dailyPriceShiftExponent;
    uint256 centerednessMargin;
}

/**
 * @notice Weighted settings of a staking rewards pool.
 * @param tokens The pool tokens, in any order (2 up to the Vault's maximum)
 * @param weights The weight of each token in `tokens`, 18-decimal FP, adding up to 100% (each at least 1%)
 */
struct StakingRewardsWeightedParams {
    IERC20[] tokens;
    uint256[] weights;
}

/**
 * @notice Launches staking rewards pools: standard ReClamm or weighted pools, created through their own factories, whose pool
 * creator is one shared treasury. The treasury turns their creator fees into rewards for one staking rack (of one
 * token, e.g., $WIF), paid in the BPT of every approved index pool, and into locked liquidity.
 * @dev The launcher deploys the treasury (which deploys the rack) on construction, and is the only account that can
 * register pools with it. Each launch creates the pool with the treasury as pool creator, no pause manager and no swap
 * fee manager (so its swap fee is fixed), then registers it, and the treasury sets its creator fee right away: the
 * pool is registered with the Vault, which is all the fee controller needs, and initialization keeps the fee.
 *
 * Anyone can launch a pool feeding an index pool the treasury's curator approved, if that index holds all of the
 * pool's tokens (the treasury refuses others). Only the curator can launch a self-rewarding weighted pool, which is its
 * own index: each one takes one of the rack's limited reward token slots, for good. The pools are plain factory pools
 * (`isPoolFromFactory` on their factory).
 */
contract StakingRewardsLauncher {
    using FixedPoint for uint256;

    // LPs always keep at least 10% of the fees (after the protocol's).
    uint256 public constant MAX_CREATOR_FEE_PERCENTAGE = 90e16; // 90%

    uint256 public constant MAX_STAKER_SHARE = FixedPoint.ONE; // 100%

    IVault public immutable vault;
    ReClammPoolFactory public immutable reClammFactory;
    WeightedPoolFactory public immutable weightedFactory;
    StakingRewardsTreasury public immutable treasury;

    /// @notice `indexPool` is the pool itself if it is self-rewarding.
    event StakingRewardsPoolCreated(address indexed pool, address indexed factory, address indexed indexPool);

    /// @notice A pool factory was deployed with another Vault.
    error WrongFactoryVault(address factory);

    /// @notice A token appears twice.
    error DuplicateToken(IERC20 token);

    /// @notice The creator fee is above MAX_CREATOR_FEE_PERCENTAGE.
    error CreatorFeeTooHigh();

    /// @notice The staker share is above MAX_STAKER_SHARE.
    error StakerShareTooHigh();

    /// @notice Only the treasury's curator can launch self-rewarding pools.
    error SenderIsNotCurator();

    /**
     * @param reClammFactory_ The ReClamm pool factory
     * @param weightedFactory_ The weighted pool factory (of the same Vault)
     * @param stakingToken The token the rack stakes (e.g., $WIF)
     * @param curator The account that approves index pools and launches self-rewarding pools
     */
    constructor(
        ReClammPoolFactory reClammFactory_,
        WeightedPoolFactory weightedFactory_,
        IERC20 stakingToken,
        address curator
    ) {
        IVault vault_ = reClammFactory_.getVault();
        require(weightedFactory_.getVault() == vault_, WrongFactoryVault(address(weightedFactory_)));

        vault = vault_;
        reClammFactory = reClammFactory_;
        weightedFactory = weightedFactory_;
        treasury = new StakingRewardsTreasury(vault_, stakingToken, curator);
    }

    /// @notice The staking rack of the treasury.
    function rack() external view returns (address) {
        return address(treasury.rack());
    }

    /**
     * @notice Creates a staking rewards ReClamm pool and registers it with the treasury.
     * @param params The staking rewards settings (see `StakingRewardsParams`)
     * @param reClammParams The tokens and price range (see `StakingRewardsReClammParams`), with prices of the base token in
     * the quote token whichever way the tokens sort
     * @param indexPool An approved index pool holding both tokens
     * @param salt The salt for deployment (combined with the caller, so nobody can take another's address)
     * @return pool The pool address
     */
    function createReClammPool(
        StakingRewardsParams memory params,
        StakingRewardsReClammParams memory reClammParams,
        address indexPool,
        bytes32 salt
    ) external returns (address pool) {
        _validate(params);
        IERC20 baseToken = reClammParams.baseToken;
        require(baseToken != reClammParams.quoteToken, DuplicateToken(baseToken));

        uint256 baseTokenIndex = address(baseToken) < address(reClammParams.quoteToken) ? 0 : 1;
        TokenConfig[] memory tokens = new TokenConfig[](2);
        tokens[baseTokenIndex] = _tokenConfig(baseToken);
        tokens[1 - baseTokenIndex] = _tokenConfig(reClammParams.quoteToken);

        pool = reClammFactory.create(
            params.name,
            params.symbol,
            tokens,
            _roleAccounts(),
            params.swapFeePercentage,
            _priceParams(reClammParams, baseTokenIndex),
            reClammParams.dailyPriceShiftExponent,
            reClammParams.centerednessMargin,
            _salt(salt)
        );

        _register(pool, address(reClammFactory), indexPool, params);
    }

    /**
     * @notice Creates a staking rewards weighted pool feeding an index pool, and registers it with the treasury.
     * @param params The staking rewards settings (see `StakingRewardsParams`)
     * @param weightedParams The tokens and weights (see `StakingRewardsWeightedParams`)
     * @param indexPool An approved index pool holding all of the pool's tokens
     * @param salt The salt for deployment (combined with the caller, so nobody can take another's address)
     * @return pool The pool address
     */
    function createWeightedPool(
        StakingRewardsParams memory params,
        StakingRewardsWeightedParams memory weightedParams,
        address indexPool,
        bytes32 salt
    ) external returns (address pool) {
        pool = _createWeighted(params, weightedParams, salt);
        _register(pool, address(weightedFactory), indexPool, params);
    }

    /**
     * @notice Creates a self-rewarding weighted pool (e.g., WIF, WETH and RWA tokens): its staker share goes
     * back into it (one-sided, capped like any index add), its own BPT is the reward, and other staking rewards pools may feed
     * it as an index. Curator only.
     * @param params The staking rewards settings (see `StakingRewardsParams`)
     * @param weightedParams The tokens and weights (see `StakingRewardsWeightedParams`)
     * @param salt The salt for deployment (combined with the caller, so nobody can take another's address)
     * @return pool The pool address
     */
    function createSelfRewardingWeightedPool(
        StakingRewardsParams memory params,
        StakingRewardsWeightedParams memory weightedParams,
        bytes32 salt
    ) external returns (address pool) {
        require(msg.sender == treasury.curator(), SenderIsNotCurator());

        pool = _createWeighted(params, weightedParams, salt);
        _register(pool, address(weightedFactory), pool, params);
    }

    function _createWeighted(
        StakingRewardsParams memory params,
        StakingRewardsWeightedParams memory weightedParams,
        bytes32 salt
    ) internal returns (address) {
        _validate(params);
        (TokenConfig[] memory tokens, uint256[] memory weights) = _sortWeighted(weightedParams);

        return
            weightedFactory.create(
                params.name,
                params.symbol,
                tokens,
                weights,
                _roleAccounts(),
                params.swapFeePercentage,
                address(0), // no hooks
                false, // no donations
                false, // unbalanced liquidity allowed (so the pool can be an index)
                _salt(salt)
            );
    }

    function _validate(StakingRewardsParams memory params) internal pure {
        require(params.creatorFeePercentage <= MAX_CREATOR_FEE_PERCENTAGE, CreatorFeeTooHigh());
        require(params.stakerShare <= MAX_STAKER_SHARE, StakerShareTooHigh());
    }

    // The tokens in Vault order, with their weights; the pool checks the weights (minimum and sum) and the Vault the
    // token count.
    function _sortWeighted(
        StakingRewardsWeightedParams memory weightedParams
    ) internal pure returns (TokenConfig[] memory tokens, uint256[] memory weights) {
        IERC20[] memory list = weightedParams.tokens;
        weights = weightedParams.weights;
        InputHelpers.ensureInputLengthMatch(list.length, weights.length);

        // Insertion sort, moving each weight with its token (in copies: the caller's arrays stay as given).
        IERC20[] memory sorted = new IERC20[](list.length);
        uint256[] memory sortedWeights = new uint256[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            uint256 j = i;
            while (j > 0 && address(sorted[j - 1]) > address(list[i])) {
                sorted[j] = sorted[j - 1];
                sortedWeights[j] = sortedWeights[j - 1];
                --j;
            }
            sorted[j] = list[i];
            sortedWeights[j] = weights[i];
        }

        tokens = new TokenConfig[](list.length);
        for (uint256 i = 0; i < sorted.length; ++i) {
            require(i == 0 || sorted[i] != sorted[i - 1], DuplicateToken(sorted[i]));
            tokens[i] = _tokenConfig(sorted[i]);
        }
        weights = sortedWeights;
    }

    function _tokenConfig(IERC20 token) internal pure returns (TokenConfig memory) {
        return
            TokenConfig({
                token: token,
                tokenType: TokenType.STANDARD,
                rateProvider: IRateProvider(address(0)),
                paysYieldFees: false
            });
    }

    function _roleAccounts() internal view returns (PoolRoleAccounts memory) {
        return PoolRoleAccounts({ pauseManager: address(0), swapFeeManager: address(0), poolCreator: address(treasury) });
    }

    // ReClamm prices are of token A (index 0) in token B. The parameters give the base token's price in the quote
    // token, so if the base token is B, invert them (the minimum and maximum swap).
    function _priceParams(
        StakingRewardsReClammParams memory reClammParams,
        uint256 baseTokenIndex
    ) internal pure returns (ReClammPriceParams memory priceParams) {
        (priceParams.initialMinPrice, priceParams.initialMaxPrice, priceParams.initialTargetPrice) = baseTokenIndex == 0
            ? (reClammParams.initialMinPrice, reClammParams.initialMaxPrice, reClammParams.initialTargetPrice)
            : (
                FixedPoint.ONE.divDown(reClammParams.initialMaxPrice),
                FixedPoint.ONE.divDown(reClammParams.initialMinPrice),
                FixedPoint.ONE.divDown(reClammParams.initialTargetPrice)
            );
    }

    // Every launch goes through this contract, so the factories see one deployer: key the salt by the caller.
    function _salt(bytes32 salt) internal view returns (bytes32) {
        return keccak256(abi.encode(msg.sender, salt));
    }

    function _register(address pool, address factory, address indexPool, StakingRewardsParams memory params) internal {
        // Reverts unless the index pool is approved (or is the pool) and holds all of its tokens; sets the creator fee.
        treasury.registerPool(pool, indexPool, params.stakerShare, params.creatorFeePercentage);

        emit StakingRewardsPoolCreated(pool, factory, indexPool);
    }
}
