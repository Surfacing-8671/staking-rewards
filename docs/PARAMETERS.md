# StakingRewardsLauncher — Parameters

Constructor: `(reClammFactory, weightedFactory, stakingToken, curator)`. Both factories must use the same Vault
(`WrongFactoryVault`). It deploys the one `StakingRewardsTreasury` (which deploys the one `StakingRewardsRack`, staking
`stakingToken`, e.g. WIF); the `curator` approves index pools with `treasury.allowIndexPool`, and launches
self-rewarding pools.

- `createReClammPool(StakingRewardsParams params, StakingRewardsReClammParams reClammParams, address indexPool, bytes32 salt) → pool`
- `createWeightedPool(StakingRewardsParams params, StakingRewardsWeightedParams weightedParams, address indexPool, bytes32 salt) → pool`
- `createSelfRewardingWeightedPool(StakingRewardsParams params, StakingRewardsWeightedParams weightedParams, bytes32 salt) → pool`
  (curator only: `SenderIsNotCurator`)

`StakingRewardsParams` (every pool type):

| Parameter | Type | $WIF launch | Min | Max | Meaning | Enforced by |
| --- | --- | --- | --- | --- | --- | --- |
| `name` / `symbol` | `string` | — | | | BPT name and symbol | — |
| `swapFeePercentage` | `uint256` (18 dec) | — | ReClamm 0.001%, weighted 0.05% | 10% | The pool's swap fee, fixed at creation | Vault (the pool type's bounds): `SwapFeePercentageTooLow` / `TooHigh` |
| `creatorFeePercentage` | `uint256` (18 dec) | 50% | 0 | 90% | Share of swap fees (after the protocol's) to the treasury; LPs keep the rest | `CreatorFeeTooHigh` |
| `stakerShare` | `uint256` (18 dec) | 50% | 0 | 100% | Share of each harvest's new fees that goes to stakers, as index BPT; the rest becomes POL | `StakerShareTooHigh` |

`indexPool` (ReClamm and `createWeightedPool`): a curator-approved index pool holding all of the pool's tokens; the
pool's staker share goes into it. `treasury.registerPool` enforces it: `IndexPoolNotAllowed`, `IndexPoolMissingToken`.
A self-rewarding pool is its own index.

`StakingRewardsReClammParams` (ReClamm only; prices of `baseToken` in `quoteToken`, inverted by the launcher if `baseToken`
sorts second):

| Parameter | Type | Min | Max | Meaning | Enforced by |
| --- | --- | --- | --- | --- | --- |
| `baseToken` | `IERC20` | | | One pool token (e.g., WIF); the prices are given for it | `DuplicateToken` |
| `quoteToken` | `IERC20` | | | The other pool token (e.g., WETH) | `DuplicateToken` |
| `initialMinPrice` | `uint256` (18 dec) | > 0 | | Lowest price | `ReClammPoolFactoryLib.validatePoolParams` |
| `initialMaxPrice` | `uint256` (18 dec) | | 20× min | Highest price | same; `PriceRatioAboveMax` above 20× |
| `initialTargetPrice` | `uint256` (18 dec) | min | < max | Starting price; must be centered enough for the margin | same; `InvalidInitialTargetPrice` |
| `dailyPriceShiftExponent` | `uint256` (18 dec) | 0 or ≥ 124649 wei | 50% | How fast the range follows the market when out of range (2^x per day) | same |
| `centerednessMargin` | `uint256` (18 dec) | 0 | 90% | How far from the center the price may go before the range moves | same |

`StakingRewardsWeightedParams` (weighted only):

| Parameter | Type | Min | Max | Meaning | Enforced by |
| --- | --- | --- | --- | --- | --- |
| `tokens` | `IERC20[]` | 2 | 8 | The pool tokens, in any order; the launcher sorts them, with their weights | `DuplicateToken`; the Vault (count) |
| `weights` | `uint256[]` (18 dec) | 1% each | | One per token, adding up to 100% | `InputLengthMismatch`; the pool (`MinWeight`, `NormalizedWeightInvariant`) |

`salt`: CREATE2 salt, combined with the caller (`keccak256(abi.encode(caller, salt))`) before it reaches the factory.

Fixed by the launcher:

| Setting | ReClamm | Weighted |
| --- | --- | --- |
| Tokens | Both `STANDARD`, no rate providers | same |
| Pause manager / swap fee manager | none | none |
| Pool creator | the treasury | the treasury |
| Creator fee | set by the treasury at launch, never changed | same |
| Protocol fee exempt | no | no |
| Liquidity | proportional only, no donations | unbalanced allowed (so it can be an index), no donations |
| Hook | the pool itself (stock ReClamm) | none |

Treasury and rack constants:

| Constant | Value |
| --- | --- |
| `StakingRewardsTreasury.HARVEST_INTERVAL` | 1 day per pool (the first harvest may run any time) |
| `StakingRewardsTreasury.MIN_POL_BPT` | `1e9` |
| `StakingRewardsTreasury.MAX_INDEX_ADD_RATIO` | 1% of the index's balance of each token, per harvest; the index's static swap fee lowers it further |
| `StakingRewardsTreasury.MIN_INDEX_ADD_SCALED18` | `1e9` (smaller index adds of a token are skipped) |
| `StakingRewardsTreasury.MIN_INDEX_ADD_RATIO` | 1e-10 of the index's balance of that token (smaller index adds are skipped: the Vault's unbalanced add maths can underflow on dust) |
| POL safety margin | 1 ppm |
| `StakingRewardsRack.REWARD_DURATION` | 7 days |
| `StakingRewardsRack.MAX_REWARD_TOKENS` | 8 (approved index pools) |

## Example: $WIF launch

With a 1% swap fee, 50% creator fee, 50% staker share and 0% protocol fee, each trade pays 0.50% to LPs, 0.25% to stakers (as index BPT), 0.25% to POL. With a protocol fee `p`, the treasury
gets `creatorFeePercentage × (1 − p)` of each fee.
