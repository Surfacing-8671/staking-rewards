# StakingRewardsLauncher — Gas Characteristics

Measured with `forge test --match-contract StakingRewardsProtocolFeeTest --gas-report` (local Vault mock, 20% protocol
fee). Numbers are for the call itself, including the Vault work it triggers (medians unless noted).

| Call | Gas | Notes |
| --- | --- | --- |
| Swap overhead vs a plain pool | none | The pools are stock ReClamm / weighted pools; the launcher adds no hooks |
| `StakingRewardsLauncher.createReClammPool` | ~6.6M | Deploys the pool through the ReClamm factory, registers it with the Vault and the treasury, sets the creator fee |
| `StakingRewardsLauncher.createWeightedPool` | ~4.1M (2 tokens) – ~4.5M (3 tokens) | Same, through the weighted factory |
| `StakingRewardsLauncher.createSelfRewardingWeightedPool` | ~4.6M (3 tokens) | Also approves the pool as an index and adds it to the rack's reward tokens |
| `StakingRewardsTreasury.allowIndexPool` | ~143k | Adds a reward token to the rack |
| `StakingRewardsTreasury.harvest(pool)` | ~845k typical, ~1.23M max | Fee collection + withdrawal, recycle, unbalanced add to the index (a 6-token weighted index, or the pool itself), reward stream, proportional POL add; grows with the pool's token count |
| `StakingRewardsRack.stake` | ~136k | With 2 reward tokens; each extra reward token adds a few thousand to every stake, withdraw and claim |
| `StakingRewardsRack.withdraw` | ~138k | |
| `StakingRewardsRack.exit` | ~84k–188k | Withdraw + claim all |

On Robinhood Chain (an Arbitrum Orbit chain), L2 execution gas is cheap; `harvest` runs once a day at most.
