# StakingRewardsLauncher

Launches standard ReClamm pools (two tokens) or weighted pools (two up to the Vault's maximum of eight), through their
own factories, with one shared treasury as pool creator. The treasury turns their creator fees into permanent
liquidity and into rewards for one staking pool: $WIF stakers earn the BPT of every approved index pool (e.g., WIF,
WETH and RWA tokens), one reward stream per index. Built for Robinhood Chain: WIF/WETH, and any other pair an index
holds (e.g., META/SPY).

- Contracts: [`contracts/staking-rewards`](contracts/staking-rewards)
- Tests: [`test/foundry`](test/foundry) (`npm test`), with a fork test against the live Robinhood Chain Vault
  (`npm run test:fork`)
- Maths: unchanged. The pools are stock `ReClammPool` / `WeightedPool` pools (pool types `RECLAMM` / `WEIGHTED`)
- Parameters: [docs/PARAMETERS.md](docs/PARAMETERS.md) · Gas: [docs/GAS_CHARACTERISTICS.md](docs/GAS_CHARACTERISTICS.md)
- License: GPL-3.0-or-later

## Setup

Needs [Foundry](https://book.getfoundry.sh) and Node.js.

```sh
npm install   # Solidity dependencies (Bush v3 packages, OpenZeppelin, forge-std, permit2)
npm test      # unit, fuzz and invariant tests
npm run test:fork   # against the live Robinhood Chain Vault (set LIVE_RPC_URL to use another RPC)
npm run gas   # gas report
```

## Layout

- `contracts/staking-rewards/`: `StakingRewardsLauncher`, `StakingRewardsTreasury`, `StakingRewardsRack`.
- `contracts/reclamm/`, `contracts/weighted/`: the ReClamm and weighted pools and factories the launcher creates pools
  through, copied unchanged from the Bush pool factories (they are not published as packages). Deploy the launcher
  with the deployed factories' addresses; these copies are what the tests run against.

## How it works

```
traders swap WIF/WETH  ── swapFeePercentage, charged in the token going in
        │
        ▼
 ┌──────────────┬──────────────────────────────┐
 │ LPs          │ creatorFeePercentage → StakingRewardsTreasury (pool creator)
 └──────────────┴──────────┬───────────────────┘
                           │ harvest() — anyone, once a day
              ┌────────────┴─────────────┐
              ▼                          ▼
   stakerShare: WIF + WETH added   rest → proportional add to the pool
   one-sided to the index pool     (BPT held by the treasury, which has
   (WIF, WETH, 4 RWAs, weighted)    no way to move it: locked for good)
              │ index BPT
              ▼
   StakingRewardsRack: WIF stakers earn
   index BPT, streamed over 7 days
```

That is one pool. Every pool of the launcher does the same into the same treasury and rack, each with its own index
pool (several pools may share one); stakers earn every index's BPT.

A **self-rewarding** weighted pool is its own index: e.g., a WIF/WETH/RWA pool whose staker share goes back into
itself, and whose own BPT is what stakers earn. Other staking rewards pools holding its tokens may feed it too, like any
index.

Stakers end up with weighted LP exposure to WIF alongside the RWAs: the index's own trading rebalances the WIF and
WETH that go in into the other tokens.

No emissions: if nobody trades, nobody earns.

### `StakingRewardsLauncher`

The constructor takes the existing `ReClammPoolFactory` and `WeightedPoolFactory` (same Vault, or
`WrongFactoryVault`), the staking token (WIF) and a `curator`, and deploys the treasury (which deploys the rack). The
launcher is the only account that can register pools with the treasury.

- `createReClammPool(StakingRewardsParams, StakingRewardsReClammParams, indexPool, salt) → pool`. Prices are given as the base
  token's price in the quote token, whichever way the tokens sort; the launcher inverts them when the base token is
  ReClamm's token B.
- `createWeightedPool(StakingRewardsParams, StakingRewardsWeightedParams, indexPool, salt) → pool`. Tokens and weights in any
  order (the launcher sorts them together); the weights add up to 100%, each at least 1% (enforced by the pool).
- `createSelfRewardingWeightedPool(StakingRewardsParams, StakingRewardsWeightedParams, salt) → pool`. **Curator only**: the pool
  becomes a reward token of the rack, which takes at most 8, for good, so a stranger must not be able to use up the
  slots.

The first two are open to anyone, but only on a curator-approved index pool that holds all of the pool's tokens (the
treasury refuses others). Each launch, in one transaction:

1. calls the factory's own `create`, so the pool is a plain factory pool (`isPoolFromFactory` on that factory), with:
   - its `swapFeePercentage`, within the pool type's bounds (enforced by the Vault), and fixed: no swap fee manager;
   - no pause manager;
   - the treasury as pool creator;
   - no hooks beyond the pool's own (ReClamm is its own hook; weighted pools have none);
   - ReClamm: proportional liquidity only, no donations (ReClamm requires it). Weighted: unbalanced liquidity allowed,
     no donations;
2. calls `treasury.registerPool(pool, indexPool, stakerShare, creatorFeePercentage)`, which records the pool and sets
   its creator fee at once. Only the pool creator can set it, and the treasury is the pool creator. For a
   self-rewarding pool, `indexPool` is the pool itself, and registering it also approves it as an index pool.

The salt is keyed by the caller (`keccak256(caller, salt)`), since every launch reaches the factories from the same
address: nobody can take another caller's pool address first.

**Why setting the fee before initialization is safe.** The fee controller only needs the pool registered with the
Vault. `initialize` loads the pool's config at its start and writes it back at its end, so it keeps a fee set before
it; only a change made *inside* `onBeforeInitialize` would be lost. Tested locally (the fee and the Vault's aggregate
fee are checked at launch and after initialization, and the invariant suite checks them after every step) and against
the live Vault on a fork (`npm run test:fork`).

### `StakingRewardsTreasury` (one for all pools)

The pool creator of every staking rewards pool, ReClamm or weighted, of any token count (its ledger has one entry per pool
token). Pools never touch each other's tokens: each has its own ledger of tokens
reserved for stakers and carried over for POL, fees are measured across that pool's own fee withdrawal, and the
treasury never acts on its total balances (tested: with two pools sharing WETH, the treasury's balance of each token
equals the sum of the ledgers).

`allowIndexPool(index)` — curator only: approves an index pool (registered, accepting unbalanced liquidity) and adds
its BPT to the rack's reward tokens. Approvals can't be undone, and the rack takes at most 8.

`registerPool(pool, indexPool, stakerShare, creatorFeePercentage)` — launcher only, once per pool: reads the pool's
tokens from the Vault, checks the index pool is approved (or approves the pool itself, if self-rewarding) and holds
all of them (`IndexPoolNotAllowed`, `IndexPoolMissingToken`), and sets the creator fee. The treasury never changes it
afterwards.

`harvest(pool)` — permissionless, once per day per pool, once the pool is initialized (`PoolNotInitialized`):

1. Collect the pool's aggregate fees and withdraw the creator share to itself. New fees = balance delta.
2. Take back from the rack this index's stream that accrued while nobody was staked (held per index pool).
3. If anyone is staked: reserve `stakerShare` of each token's new fees for stakers, add as much of the reserve as the
   cap allows to the pool's index (unbalanced, only the pool's own tokens; for a self-rewarding pool, into itself),
   and stream the new BPT, plus any recycled for that index, to the rack. With nobody staked, all new fees go to POL.
4. Add the largest proportional amount its unreserved balances (new fees + carry-over) pay for, minus 1 ppm, as POL
   (skipped below `1e9` BPT).

Both adds run in a `try/catch`, so one failing (e.g., a pool paused) never blocks the other; the tokens carry over,
and the reserve stays the stakers' (tested).

The POL add is proportional, so it has no price impact and can't be sandwiched. Whatever can't be paired carries over:
e.g., if sells of WIF dominate, the fees are mostly WIF, which piles up in the treasury, effectively out of circulation
until the other side catches up. With more than two tokens, the least traded token sets the pace: a pool where one
token rarely trades in adds little POL, and the rest of its carry-over waits.

The staker share goes in one-sided instead, so it does not wait for the least traded token. That holds for a
self-rewarding pool too: a proportional add into itself would be safe from sandwiches, but would be held back the
same way (tested: a WIF/WETH/USDC pool where only WIF and WETH trade still streams its stakers' BPT).

The index add is one-sided, so it *can* be sandwiched: someone sells WIF into the index first, so the add buys less
BPT, then buys it back. Each harvest adds at most the index's static swap fee, and never more than
`MAX_INDEX_ADD_RATIO` (1%), of the index's balance of each token; the rest of the reserve goes in with later harvests
(tested). The add then moves the index's price by about its fee at most, while the attacker's round trip pays that fee
twice, so a sandwich doesn't pay at any index fee (fuzzed from 0.05%, the weighted pool minimum, to 10%). The fee is
read at each harvest, so the cap follows it if the index's swap fee manager changes it. The trade-off: a low-fee index
takes the staker share in more slowly (e.g., a 0.1% fee lets in 0.1% of the index's balance per harvest). An index
whose dynamic fee hook charges less than its static fee weakens the bound.

### Index pools (deployed by you, approved by the curator)

Any Vault pool that accepts unbalanced liquidity (`IndexPoolNeedsUnbalancedLiquidity`); a staking rewards pool can only use
one that holds both of its tokens (`IndexPoolMissingToken`), so the approved indexes decide which pairs can launch. For $WIF: a `WeightedPool`
of WIF, WETH and four RWA tokens. The weights must sum to 100%, so with WIF at 40%, the other five share 60% (e.g.,
12% each). Its swap fee, pause manager and other roles are yours to choose; the launcher doesn't touch them.

### `StakingRewardsRack` (one, staking WIF)

Synthetix-style multi-reward staking: one 7-day stream per approved index pool's BPT. A staker who arrives just before
a harvest and leaves just after only gets their time share (tested: 100× the stake for one hour earns ≤ 1/168).

- Staking and withdrawing never transfer a reward token, so a reward that can't be transferred never traps a stake
  (tested). Claim everything with `getReward()`, or one token with `getReward(token)`.
- Only the treasury adds reward tokens, at most `MAX_REWARD_TOKENS` (8): every stake, withdraw and claim loops over
  them. They are never removed; a finished stream just stops.
- It tracks everything it owes per token and refuses a stream its balance can't cover.

No owner, no pause, no withdrawal delay.

## ReClamm or weighted

- **ReClamm: concentrated depth.** Liquidity sits in a price range, so the same TVL quotes tighter prices than a
  full-range weighted pool, which helps the "aggregators route here" side of the loop. LPs hold both tokens at
  the pool's price, like a 50/50 pool within the range, and the range has to keep up with the token (see below).
- **Weighted (e.g., 80/20): full range, skewed exposure.** Never out of range, whatever the token does, and LPs keep
  most of their exposure in the base token, with less impermanent loss than a 50/50 position. Shallower quotes for
  the same TVL.

## Before mainnet

- [ ] **Reward slots.** Approved indexes and self-rewarding pools share the rack's 8 reward token slots, for good.
  Plan which ones get them.
- [x] **Contract size.** The launcher itself is small, but `ReClammPool` (~26.5 KB with the via-IR build) is over
  Ethereum's 24,576-byte EIP-170 limit. Robinhood Chain accepts it (40,000-byte code); a chain enforcing EIP-170
  would not. The launcher's initcode deploys the treasury and rack.
- [ ] **Concentration.** One treasury and one rack hold every pool's POL and every staker's rewards, with no owner and
  no upgrades: a bug there affects all pools at once. Audit accordingly.
- [ ] **Curator key.** It can only approve index pools (it can't move funds), but each approval permanently uses one of
  the 8 reward slots. Use a multisig.
- [ ] **Price range vs a memecoin (ReClamm pools).** ReClamm's range is at most 20× wide (`MAX_PRICE_RATIO`) and follows the market
  at most 2^`dailyPriceShiftExponent` per day (≤ ~1.41×/day at the 50% maximum). A move faster or bigger than that
  leaves the pool one-sided at a stale edge until the range catches up; arbitrageurs trade it there, at the LPs'
  expense. Pick the range and shift exponent with WIF's volatility in mind.
- [x] **WIF is a plain ERC-20.** Checked against Robinhood Chain (block 95,021,918): 1,805 bytes of code, no proxy
  and no `delegatecall` (not upgradeable), owner renounced to `0x…dEaD`, only the standard ERC-20 functions plus one
  unnamed view (`0x43000814`, likely the ERC-8056 display multiplier). A forked transfer of 1.19M WIF arrived exactly,
  with total supply unchanged: no transfer tax. The rack and treasury rely on that.
- [ ] Robinhood Chain addresses: Vault `0xB055000fbE3cc9bDE7742C583a86cc6283E3fF85`,
  WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`. WIF `0xE49A1C3033EcC6b804bc423021D3F71F1A3e0F9B`.
- [ ] **RWA tokens in the index.** Check each one like WIF above: no transfer tax or rebasing. Tokenized stocks often
  have transfer restrictions (blocklists, pauses outside market hours, KYC'd holders): a paused RWA blocks swaps in
  the index, and the Vault may refuse to hold a blocklisted token. The treasury survives a failed index add (the
  staker share stays reserved), but stakers' BPT is only as liquid as the index's least liquid token. Stock splits
  shown through an ERC-8056 display multiplier don't change raw balances, so the weighted maths is unaffected.
- [ ] Index pool depth and fee: keep it deep relative to a day's staker share, or the cap (the index's fee, at most
  1%) holds most of it in reserve.
- [ ] Deployment script (the launcher takes the deployed ReClamm and weighted factories). Fork test: done.
- [ ] Seeding: who provides the initial WIF/WETH for the staking rewards pool, and WIF/WETH/RWAs for the index, and how much.
- [ ] Audit (treasury and rack).
