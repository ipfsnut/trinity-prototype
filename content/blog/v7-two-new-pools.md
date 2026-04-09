---
title: "V7: Two New Pools, A Burn Engine, and What Comes Next"
date: "2026-04-09"
summary: "We deployed two new TRINI bonding curve pools using a single-pool hook architecture with 5% fees, retired the $CHAOSLP pool, and started thinking about what TRINI looks like as a community project."
---

Today we deployed two new TRINI bonding curve pools on Base using a new single-pool hook architecture (V7), alongside the existing V6 pools that have been running since launch. This post explains what changed, why, and where the project is headed.

## Background: How V6 Works

Trinity launched with three V6 bonding curve pools — TRINI/USDC, TRINI/WETH, and TRINI/$CHAOSLP — managed by a single Uniswap V4 hook contract. Each pool uses discrete LP bands that approximate a bonding curve, with a 1% asymmetric fee: buys send 1% of the quote asset to the community treasury, sells burn 1% of TRINI to 0xdead.

The three pools create a permanent arbitrage surface. When ETH, USDC, or $CHAOSLP move relative to each other, the TRINI price across pools diverges. Arb bots equalize the prices, paying fees and burning TRINI in the process. Volatility generates yield and deflation.

## What We Learned

After analyzing on-chain activity, we found two things:

- **The $CHAOSLP pool was overweight.** With 153M TRINI backing a token with a $2,560 FDV, the pool was a brick wall. The entire $CHAOSLP supply couldn't push through Band 0. No price discovery was happening.

- **The 1% fee on arb-generating pools left value on the table.** Small ETH moves triggered frequent but tiny arbs. Each cycle burned very little TRINI. The fee was set for trading venues, not burn engines.

## V7: Single-Pool Hooks at 5%

V7 introduces a new architecture: one hook per pool. Each V7 hook manages exactly one bonding curve with its own fee, band schedule, and lifecycle. This eliminates the cross-pool token contamination issue from V6's multi-pool design, and lets us set different fees per quote asset.

We deployed two V7 hooks today:

- **TRINI/Clanker (84M TRINI, 5% fee)** — The primary volatility engine. Clanker is volatile ($25M mcap, $433K daily volume) and partially decorrelated from ETH. The 5% fee creates a ±6% dead zone: Clanker has to move 6%+ before arbs fire. Each arb event burns ~3-4x more than the V6 pools.

- **TRINI/WETH (50M TRINI, 5% fee)** — A responsive ETH pool that complements the deep V6 WETH pool (297M at 1%).

## The Graduated Fee Structure

The system now operates on a tiered model:

| Pool | Fee | TRINI | Role |
|------|-----|-------|------|
| USDC (V6) | 1% | 450M | Anchor & primary trading venue |
| WETH (V6) | 1% | 297M | Deep ETH on-ramp |
| WETH (V7) | 5% | 50M | Responsive ETH arb surface |
| Clanker (V7) | 5% | 84M | Volatility engine |

Small market moves only hit the 1% pools (frequent, low-burn). Larger moves crack open the 5% pools (less frequent, high-burn). The burn rate scales with the price action.

## Contracts

All contracts are on Base mainnet. The V7 hook source is verified on Basescan.

**TRINI Token**
- `0x17790eFD4896A981Db1d9607A301BC4F7407F3dF`

**V6 Hook** (USDC + WETH + $CHAOSLP pools, 1% fee)
- `0xe89a658e4bec91caea242aD032280a5D3015C8c8`

**V7 Hook — Clanker** (5% fee, 84M TRINI, 9 bands)
- `0x9f35560a57666Bc8A8889A87f220bA282b57c8C8`

**V7 Hook — WETH** (5% fee, 50M TRINI, 9 bands)
- `0x07e1E16dfa4Fc5418CEf383E0D22EE139aE108C8`

**Staking Hub**
- `0x76F63BB9990a1afdB1c426394D3Fc2448FBe77d6`

**Multisig (Safe)**
- `0xb7DD467A573809218aAE30EB2c60e8AE3a9198a0`

**Uniswap V4 PoolManager (Base)**
- `0x498581fF718922c3f8e6A244956aF099B2652b2b`

## Dropping the Prototype Label

Trinity started as a bonding curve experiment. Five hook versions, many ai-assisted reviews, and a live deployment later, the mechanism works. Arb bots find the pools. Fees flow to treasury. TRINI burns on every sell. Band transitions fire when price moves through the curve.

We're exploring what it looks like to transition TRINI from a prototype into a community project focused on two things:

- **Yield farming** — The staking hub is live. Treasury fees from the 1% and 5% pools fund staking rewards. As more pools come online and volume grows, the yield compounds.

- **Bonding curve R&D** — Each V7 hook is a self-contained experiment. We can deploy new curves for new assets (cbBTC, LINK, whatever) without touching the existing infrastructure. The single-pool architecture makes iteration cheap.

When the time is right, the prototype label will be dropped from Trinity and a team will be announced. The purpose will be to develop and maintain decentralized financial tools in the vein of exploration first explored by ArbMe.

