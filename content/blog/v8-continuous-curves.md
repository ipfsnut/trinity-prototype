---
title: "V8: Continuous Curves, The Launcher Backbone, and the End of Bands"
date: "2026-04-13"
summary: "V8 replaces discrete LP bands with a single continuous concentrated liquidity position per pool, eliminates band-transition gas costs, and introduces the launcher backbone architecture where new projects seed a 1% TRINI cross-pair pool."
---

# V8: Continuous Curves, The Launcher Backbone, and the End of Bands

Trinity's hook architecture has gone through five on-chain iterations. V8 is the most significant change since we started: it throws out the discrete LP band model entirely and replaces it with a single continuous concentrated liquidity position per pool. This post explains what changed, why, and what the launcher backbone mechanism means for the future of the project.

## What V6/V7 Did (and Why It's Gone)

V6 used discrete LP bands — 12 to 18 narrow tick ranges stacked into a bonding curve shape. The hook managed these bands by removing liquidity from one and adding it to the next whenever the price moved past a boundary. V7 refined this with single-pool hooks (one hook per pool instead of one hook managing three pools) and experimented with higher fees (5% on the arb-generating pools).

The band model worked. Arb bots found the pools, fees flowed, TRINI burned on every sell. But it had a structural problem we couldn't engineer around: **Type-A leakage**.

When price moves through a band boundary, the hook has to remove LP from the old band and add it to the new one. During that transition, the AMM has no liquidity at the current price. Any trade that lands in the gap gets a worse price than it should, and the difference leaks out of the system. Our analysis showed this leakage was 50-65% on meaningful trades — more than half the value that should have stayed in the curve was escaping during band transitions.

V7's 5% fee pools partially masked this by making the fee larger than the leak, but it was treating the symptom. The leak was structural.

## What V8 Does Differently

V8 replaces the entire band architecture with one thing: **a single continuous concentrated liquidity position spanning the full configured tick range**. All committed tokens contribute to liquidity at every price within the range. No bands. No transitions. No afterSwap rebalancing.

The contract is `TrinityHookV8.sol`. Here's what it does:

**Fee extraction via `beforeSwap`.** Before each swap touches the AMM, the hook takes a configurable fee (1% on the USDC pool, 2% on WETH and Clanker). Buy fees go to the community treasury in the quote token. Sell fees burn TRINI by sending it to `0xdead`. Same asymmetric model as V6, but parameterized per-deploy instead of hardcoded.

**External LP blocked.** `beforeAddLiquidity` reverts for any sender that isn't the hook itself. Only the hook can mint into the pool. This keeps curve depth fully controlled by the deployer — no external LP can dilute or distort the curve shape.

**No afterSwap.** V6 and V7 used afterSwap to rebalance bands when price crossed boundaries. V8 has no bands, so there's nothing to rebalance. This saves ~3,000 gas per swap and removes the most fragile piece of the old design.

**Parameterized deployment.** Token address, fee rate, tick range, and owner are constructor arguments. Any project can deploy a copy of TrinityHookV8 with their own parameters. No more hardcoded constants.

**exactOutput blocked.** Only exactInput swaps are supported. This closes the fee-bypass vector discovered in the V5 audit (where exactOutput swaps could skip the fee extraction).

### Permission Bits

```
BEFORE_ADD_LIQUIDITY        (bit 11) — block external LP permanently
BEFORE_SWAP                 (bit 7)  — fee extraction
BEFORE_SWAP_RETURNS_DELTA   (bit 3)  — modify input for fee
```

No AFTER_SWAP, no AFTER_INITIALIZE. The hook address must be mined with these specific flag bits.

## What's Live

Three V8 pools are deployed on Base mainnet:

| Pool | Fee | Hook Address |
|------|-----|-------------|
| TRINI / USDC | 1% | `0x995d479bdd10686BDfeC8E8ba5f86357211bC888` |
| TRINI / WETH | 2% | `0x089d5FFe033aF0726aAbfAf2276F269D4Fe78888` |
| TRINI / Clanker | 2% | `0x95911f10849fAB05fdf8d42599B34dC8A17b8888` |

The TRINI token is unchanged: `0x17790eFD4896A981Db1d9607A301BC4F7407F3dF` — 1B supply, CREATE2 deployed below WETH for currency0 ordering.

Staking is live via the TrinityStakingHub at `0x76F63BB9990a1afdB1c426394D3Fc2448FBe77d6`, with WETH and Clanker reward gauges distributing treasury fees to stakers on 180-day rolling streams.

## The Launcher Backbone

V8 isn't just a better hook for TRINI's own pools. It's the building block for a **token launcher** where new projects deploy their own V8 curves with TRINI as a cross-pair quote asset.

### How It Works

Each project that launches on the system deploys a standard 5-pool curve set:

| Pool | Fee | Token Committed | Function |
|------|-----|-----------------|----------|
| PROJECT/USDC | 1% | 60% of supply | Main price discovery |
| PROJECT/WETH | 2% | 10% | ETH-paired arb route |
| PROJECT/cbBTC | 2% | 10% | BTC-paired arb route |
| PROJECT/CLANKER | 2% | 10% | Memecoin-paired arb route |
| **PROJECT/TRINI** | **2%** | **1%** | **Trinity cross-pair** |

The cross-pair pool is the key piece. At deploy time, the project sources ~$50 of TRINI from the TRINI/USDC pool to seed the quote side, making it a functional two-sided market from day one. That's the only TRINI cost the project incurs.

### Why This Matters for TRINI

When a launched project has buy activity, its USDC pool's implied price for the project token rises. Arb bots equalize all the project's pools, including the TRINI cross-pair. To bring the cross-pair into line, arbers must **buy TRINI from the open market** (specifically from TRINI/USDC, the deepest TRINI venue) and use it to buy the project token from the cross-pair pool.

A single arb cycle:
1. Buy TRINI from TRINI/USDC (paying USDC) — pumps TRINI's price
2. Buy PROJECT from PROJECT/TRINI (paying TRINI) — locks TRINI in the cross-pair pool
3. Sell PROJECT to PROJECT/USDC (receiving USDC) — closes the spread

Both effects on Trinity are positive: TRINI's price rises from the buy pressure, and TRINI inventory accumulates inside the cross-pair pool. Quiet projects don't move the needle — they sit inert. Active projects drive real buy pressure.

### The Volume Thresholds

We built a year-long simulator to model cross-token dynamics. The launcher mechanism is volume-gated:

| Total Launcher Activity | Effect on TRINI |
|------------------------|-----------------|
| Below $300/day | None — below activation threshold |
| $300 - $3,000/day | Modest — 0-10% TRINI lift |
| $3,000 - $30,000/day | Meaningful — 50-500% lift, $1K+ locked |
| Above $30,000/day | Saturates — system runs through full range |

The honest summary: a launcher that only attracts small projects won't see much benefit at the TRINI layer. The projects themselves still earn fees and burn supply — just not enough cross-pair flow to materially move TRINI. The launcher needs **at least one breakout project (~$500+/day)** plus several supporting projects to really spin the flywheel.

The case for building it anyway: the downside is bounded. Quiet projects neither help nor hurt Trinity. The launcher adds optionality on the upside without taking anything away.

## V6 → V7 → V8 Comparison

| | V6 | V7 | V8 |
|---|---|---|---|
| **Architecture** | Multi-pool hook, discrete bands | Single-pool hook, discrete bands | Single-pool hook, continuous position |
| **Bands** | 12-18 per pool | 9 per pool | None |
| **afterSwap** | Band rebalancing (max 5 steps) | Band rebalancing | None — saves ~3K gas/swap |
| **Fee** | 1% hardcoded | 5% hardcoded | Parameterized (1-10%, set at deploy) |
| **Type-A leakage** | 50-65% on band transitions | Same | Eliminated — no transitions |
| **Pools per hook** | 3 | 1 | 1 |
| **Deployment** | Hardcoded constants | Hardcoded constants | Constructor args — any project can deploy |
| **Launcher support** | No | No | Yes — cross-pair backbone architecture |

## What Didn't Change

**The TRINI token.** Same address, same supply. V8 is a hook upgrade, not a token migration.

**Staking.** The TrinityStakingHub and reward gauges are untouched. Treasury fees from V8 pools flow to stakers the same way they did from V6.

**The fee model.** Buy fees still go to treasury in the quote token. Sell fees still burn TRINI to 0xdead. The asymmetry is the same — what changed is the fee rate is now configurable per pool instead of hardcoded.

**External LP blocking.** `beforeAddLiquidity` still reverts for non-hook callers. The hook controls all liquidity in the pool.

## Risks

Everything in the launch doc's risk section still applies. V8-specific additions:

**The continuous position has no "floor".** In the band model, each band was a discrete step with defined boundaries. In V8, the position spans the full range — there's no structural support at specific prices. If TRINI's price drops, it drops smoothly through the curve rather than stepping down through bands. This is actually better for traders (no band-gap slippage) but means there's no psychological "floor" at band boundaries.

**The launcher backbone is a bet on ecosystem adoption.** The simulation shows the mechanism works at scale, but "at scale" means $3K+/day of aggregate launcher activity. If no projects adopt the system, the cross-pair architecture sits inert. TRINI's own pools still function normally — you just don't get the launcher multiplier.

**Fee parametrization means trust in deployers.** V8 allows fees up to 10% (capped in the contract). Each project's deployer chooses their fee rate. A 10% fee pool is a very different experience than a 1% pool. Users should check the fee before trading on any V8 pool.

## Contracts

All verified on Basescan. Source at [github.com/ipfsnut/trinity-prototype](https://github.com/ipfsnut/trinity-prototype).

| Contract | Address |
|----------|---------|
| TRINI Token | `0x17790eFD4896A981Db1d9607A301BC4F7407F3dF` |
| V8 Hook — USDC (1%) | `0x995d479bdd10686BDfeC8E8ba5f86357211bC888` |
| V8 Hook — WETH (2%) | `0x089d5FFe033aF0726aAbfAf2276F269D4Fe78888` |
| V8 Hook — Clanker (2%) | `0x95911f10849fAB05fdf8d42599B34dC8A17b8888` |
| Staking Hub | `0x76F63BB9990a1afdB1c426394D3Fc2448FBe77d6` |
| WETH Reward Gauge | `0xC5C6eea6929A4Ec8080FE6bBCF3A192169CC5cC8` |
| Clanker Reward Gauge | `0x8E9988AACd83220410bF59eF5E2979d02a67EDC1` |

## First Launch: $EPIC

[$EPIC](https://epicdylan.com/blog/epic-launch) is the first project deployed on the V8 launcher infrastructure. 100 billion tokens across 5 continuous bonding curve pools — exactly the architecture described above. No presale, no VC allocation, no team tokens. 100% of supply in the pools.

| Pool | Fee | Supply | Hook Address |
|------|-----|--------|-------------|
| EPIC/USDC | 1% | 66% | `0xE00F736a7E935220ad1d3B0fe71B4e54f1620888` |
| EPIC/WETH | 2% | 11% | `0xF18daa92D808f8ed1AcaCc3f3ad52E2619410888` |
| EPIC/cbBTC | 2% | 11% | `0x4A38aC18dcf9f09ffe206a19D96E8DACe62a8888` |
| EPIC/Clanker | 2% | 11% | `0xa34cF6c22E02CF97d9db37e3197976964A35C888` |
| EPIC/TRINI | 2% | 1% | `0xF4E6648F7C5391CfCe0399A47231c69D8065c888` |

$EPIC token: `0x003b9aC55a8575295e4BE4901AA1645CC2132369`

The 5 pools across 5 quote assets create 10 pairwise arb surfaces. The EPIC/TRINI cross-pair is the launcher backbone connection — when $EPIC has buy activity, arbers source TRINI from the open market to equalize the cross-pair, generating buy pressure on TRINI. This is the mechanism described in the launcher section above, now live with real money.

Simulations using 30 days of real market data show the system generates 3-6% annual yield on seed capital in normal conditions, with fees roughly doubling during high-volatility periods. The continuous curve structure dampens external drawdowns by ~50% compared to the underlying assets.

Trade $EPIC at [epic.epicdylan.com](https://epic.epicdylan.com). Full launch details at [epicdylan.com/blog/epic-launch](https://epicdylan.com/blog/epic-launch).

## What's Next

With the first launch live, the open questions from the whitepaper become practical:
- Should Trinity's own range be wider than launched projects' ranges?
- What's the optimal cross-pair allocation (currently 1% of project supply)?
- How do we handle "graduation" when a project's USDC pool fully traverses its range?
- What happens when TRINI liquidity fragments across external venues?

These are design problems, not bugs. They imply a working mechanism that needs tuning, not fixing.
