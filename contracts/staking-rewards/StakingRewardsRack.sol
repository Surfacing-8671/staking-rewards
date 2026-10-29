// SPDX-License-Identifier: GPL-3.0-or-later
// solhint-disable not-rely-on-time

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ReentrancyGuardTransient } from "@bush.fi/v3-solidity-utils/contracts/openzeppelin/ReentrancyGuardTransient.sol";

/**
 * @notice Staking of one token (e.g., $WIF) for several reward tokens: the BPT of each index pool the treasury feeds
 * with staking rewards pool fees.
 * @dev Synthetix-style multi-reward staking, each reward streamed over `REWARD_DURATION`. Streaming means a staker who
 * arrives just before a harvest and leaves just after earns only their time share of a 7-day stream.
 *
 * Reliability rules:
 * - Staking and withdrawing never transfer a reward token, so a reward token that can't be transferred never traps a
 *   stake. Rewards are claimed separately, all at once (`getReward()`) or one token at a time (`getReward(token)`).
 * - Only the treasury adds reward tokens, at most `MAX_REWARD_TOKENS` (every stake, withdraw and claim loops over
 *   them), and they are never removed: a finished stream just stops.
 * - Everything owed in each token (the stream not yet earned, rewards earned but not claimed, and unallocated) is
 *   tracked in its `rewardReserve`, and `notifyRewardAmount` refuses a stream the balance can't cover.
 *
 * While nobody is staked, each stream accrues to `unallocated` instead of being lost; the treasury's harvests
 * `recycle` it and stream it again.
 *
 * No owner, no pause, no withdrawal delay.
 */
contract StakingRewardsRack is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct RewardState {
        // Tokens per second, scaled by 1e18.
        uint256 rewardRate;
        uint256 periodFinish;
        uint256 lastUpdateTime;
        // Accumulated rewards per staked token, scaled by 1e18.
        uint256 rewardPerTokenStored;
        // Streamed while nobody was staked; returned to the treasury by `recycle`.
        uint256 unallocated;
        // Everything owed: unstreamed + earned but unclaimed + unallocated.
        uint256 rewardReserve;
    }

    uint256 public constant REWARD_DURATION = 7 days;

    uint256 public constant MAX_REWARD_TOKENS = 8;

    uint256 internal constant _PRECISION = 1e18;

    IERC20 public immutable stakingToken;
    address public immutable treasury;

    uint256 public totalStaked;
    mapping(address account => uint256 amount) public balanceOf;

    IERC20[] internal _rewardTokens;
    mapping(IERC20 token => bool listed) public isRewardToken;
    mapping(IERC20 token => RewardState state) internal _rewards;
    mapping(IERC20 token => mapping(address account => uint256 paid)) public userRewardPerTokenPaid;
    mapping(IERC20 token => mapping(address account => uint256 amount)) public rewards;

    event Staked(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardTokenAdded(IERC20 indexed token);
    event RewardPaid(address indexed account, IERC20 indexed token, uint256 amount);
    event RewardAdded(IERC20 indexed token, uint256 amount, uint256 rewardRate, uint256 periodFinish);
    event Recycled(IERC20 indexed token, uint256 amount);

    /// @notice Only the treasury can add reward tokens and start streams.
    error SenderIsNotTreasury();

    /// @notice The token is not a reward token.
    error NotRewardToken(IERC20 token);

    /// @notice The token is already a reward token, or is the staking token.
    error InvalidRewardToken(IERC20 token);

    /// @notice There are already `MAX_REWARD_TOKENS` reward tokens.
    error TooManyRewardTokens();

    /// @notice The stream would promise more than the contract holds.
    error RewardTooHigh();

    /// @notice Staking or withdrawing zero.
    error ZeroAmount();

    constructor(IERC20 stakingToken_) {
        stakingToken = stakingToken_;
        treasury = msg.sender;
    }

    modifier onlyTreasury() {
        require(msg.sender == treasury, SenderIsNotTreasury());
        _;
    }

    modifier onlyRewardToken(IERC20 token) {
        require(isRewardToken[token], NotRewardToken(token));
        _;
    }

    modifier updateReward(address account) {
        uint256 length = _rewardTokens.length;
        for (uint256 i = 0; i < length; ++i) {
            _updateReward(_rewardTokens[i], account);
        }
        _;
    }

    /********************************************************
                            Views
    ********************************************************/

    function getRewardTokens() external view returns (IERC20[] memory) {
        return _rewardTokens;
    }

    function getRewardState(IERC20 token) external view onlyRewardToken(token) returns (RewardState memory) {
        return _rewards[token];
    }

    function lastTimeRewardApplicable(IERC20 token) public view returns (uint256) {
        uint256 periodFinish = _rewards[token].periodFinish;
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken(IERC20 token) public view returns (uint256) {
        RewardState storage state = _rewards[token];
        if (totalStaked == 0) {
            return state.rewardPerTokenStored;
        }
        return
            state.rewardPerTokenStored +
            ((lastTimeRewardApplicable(token) - state.lastUpdateTime) * state.rewardRate) /
            totalStaked;
    }

    function earned(IERC20 token, address account) public view returns (uint256) {
        return
            (balanceOf[account] * (rewardPerToken(token) - userRewardPerTokenPaid[token][account])) /
            _PRECISION +
            rewards[token][account];
    }

    /********************************************************
                        Staker functions
    ********************************************************/

    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, ZeroAmount());

        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    /// @notice Withdraws a stake. Never transfers rewards: they stay claimable.
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, ZeroAmount());

        totalStaked -= amount;
        balanceOf[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claims every reward token.
    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 length = _rewardTokens.length;
        for (uint256 i = 0; i < length; ++i) {
            _payReward(_rewardTokens[i], msg.sender);
        }
    }

    /// @notice Claims one reward token (e.g., if another one can't be transferred).
    function getReward(IERC20 token) external nonReentrant onlyRewardToken(token) updateReward(msg.sender) {
        _payReward(token, msg.sender);
    }

    function exit() external {
        withdraw(balanceOf[msg.sender]);
        getReward();
    }

    /********************************************************
                        Treasury functions
    ********************************************************/

    /// @notice Adds a reward token. It can never be removed.
    function addRewardToken(IERC20 token) external onlyTreasury {
        require(isRewardToken[token] == false && token != stakingToken, InvalidRewardToken(token));
        require(_rewardTokens.length < MAX_REWARD_TOKENS, TooManyRewardTokens());

        isRewardToken[token] = true;
        _rewardTokens.push(token);

        emit RewardTokenAdded(token);
    }

    /**
     * @notice Starts a new `REWARD_DURATION` stream of `amount` plus whatever is left of the current one.
     * @dev The treasury transfers `amount` in before calling.
     */
    function notifyRewardAmount(
        IERC20 token,
        uint256 amount
    ) external nonReentrant onlyTreasury onlyRewardToken(token) updateReward(address(0)) {
        RewardState storage state = _rewards[token];

        uint256 scaledAmount = amount * _PRECISION;
        if (block.timestamp < state.periodFinish) {
            scaledAmount += (state.periodFinish - block.timestamp) * state.rewardRate;
        }
        state.rewardRate = scaledAmount / REWARD_DURATION;
        state.lastUpdateTime = block.timestamp;
        state.periodFinish = block.timestamp + REWARD_DURATION;
        state.rewardReserve += amount;

        require(state.rewardReserve <= token.balanceOf(address(this)), RewardTooHigh());

        emit RewardAdded(token, amount, state.rewardRate, state.periodFinish);
    }

    /**
     * @notice Sends one token's rewards streamed while nobody was staked back to the treasury.
     * @dev Treasury only: it books the amount returned, for the index pool's next stream.
     * @return amount The amount recycled
     */
    function recycle(
        IERC20 token
    ) external nonReentrant onlyTreasury onlyRewardToken(token) updateReward(address(0)) returns (uint256 amount) {
        RewardState storage state = _rewards[token];
        amount = state.unallocated;
        if (amount > 0) {
            state.unallocated = 0;
            state.rewardReserve -= amount;
            token.safeTransfer(treasury, amount);

            emit Recycled(token, amount);
        }
    }

    /********************************************************
                            Internal
    ********************************************************/

    function _updateReward(IERC20 token, address account) internal {
        RewardState storage state = _rewards[token];
        uint256 applicable = lastTimeRewardApplicable(token);

        if (totalStaked == 0) {
            if (applicable > state.lastUpdateTime) {
                state.unallocated += ((applicable - state.lastUpdateTime) * state.rewardRate) / _PRECISION;
            }
        } else {
            state.rewardPerTokenStored = rewardPerToken(token);
        }
        state.lastUpdateTime = applicable;

        if (account != address(0)) {
            rewards[token][account] = earned(token, account);
            userRewardPerTokenPaid[token][account] = state.rewardPerTokenStored;
        }
    }

    function _payReward(IERC20 token, address account) internal {
        uint256 reward = rewards[token][account];
        if (reward > 0) {
            rewards[token][account] = 0;
            _rewards[token].rewardReserve -= reward;
            token.safeTransfer(account, reward);

            emit RewardPaid(account, token, reward);
        }
    }
}
