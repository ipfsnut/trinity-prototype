# Trinity: a launcher backbone for small token projects

> Draft research note · April 2026

## Abstract

Trinity ($TRINI) is a token designed to function as the **shared backbone of a token launcher**: small projects launching on Base each include a $TRINI cross-pair pool in their Uniswap V4 hook deployment, which puts $TRINI to work as a quote asset for those projects' bonding curves. As successful launches generate organic trading activity, arbitrage flows pump $TRINI's price *and* lock $TRINI inventory inside the cross-pair pools. Quiet projects do nothing; active projects do meaningful work. Trinity captures the upside of every successful launch in its ecosystem without ever having to extract from any project's supporters.

We built a year-long simulator that models the cross-token dynamics between $TRINI and N launched projects, including the secondary effects on the $TRINI/USDC price discovery pool. The simulation shows that **the launcher mechanism is volume-gated**: below ~$3,000/day of combined launcher activity it has no measurable effect on Trinity, and above ~$30,000/day the system saturates. In the **goldilocks zone** between those numbers — meaning at least one breakout project doing ~$500+/day plus a handful of supporting projects — Trinity's price multiple grows 4-5× and several thousand dollars of TRINI inventory accumulates locked across the cross-pair pools.

The design has **bounded downside**: quiet projects neither help nor hurt Trinity. The launcher adds optionality on the upside without taking anything away. The bet is that *some* project will eventually hit the goldilocks tier — and when one does, Trinity captures the beta.

This document describes the mechanism, walks through the simulator's volume tier comparison so prospective deployers can set their own expectations, presents the design recommendations for the next-generation hook contract, and is honest about which assumptions are load-bearing.

---

## 1. The launcher problem

Most token launches force a project's founder into an extractive role. The founder holds a large fraction of the token they just created, so the only way to make project income is to sell some of their bag — which makes them a counterparty to their own community.

The alternative we're describing is a **fee-based income model**: deploy curve infrastructure that generates fees from organic and arbitrage trading. The fees pay the founder. The token's value comes from its utility plus burns plus scarcity. The founder never sells.

For this to work at the small scale where most projects actually live ($0–$100/day of organic volume in year one), the system needs to:

1. **Generate meaningful fee income at small scale**
2. **Not extract value from the project's own users** (no Type A leakage)
3. **Capture value from external market movements** (Type B arb income)
4. **Scale gracefully as the project grows**

The previous research note ([epic-research](https://epic-research.pages.dev)) walked through what we tried first — discrete liquidity bands managed by a custom V4 hook — and showed that bands cause structural value leakage of ~50–65% on any meaningful trade. That design is dead. We've since rewritten the model around **continuous concentrated liquidity positions** (one big position per pool, no bands), which removes the leak entirely.

Continuous positions plus the multi-pool architecture gets us to the small-scale viability threshold: with $50/day organic volume, a project can generate ~$200/year in treasury fees while burning meaningful supply. That's good. But it doesn't capture the *meta* value of running many launches — and it leaves Trinity itself without a clear value model.

This document is about that meta layer.

---

## 2. The mechanism: Trinity as cross-pair backbone

### 2.1 The basic setup

Each project that launches on the launcher deploys a standard 5-pool curve set:

| Pool | Fee | EPIC committed | Function |
|---|---|---|---|
| `EPIC/USDC` | 1% | 60% of supply | Main price discovery, dollar-denominated entry |
| `EPIC/WETH` | 2% | 10% | ETH-paired arb route |
| `EPIC/cbBTC` | 2% | 10% | BTC-paired arb route |
| `EPIC/CLANKER` | 2% | 10% | Memecoin-paired arb route |
| **`EPIC/TRINI`** | 2% | **1%** | **Trinity-paired arb route** |

The `EPIC/TRINI` pool is the new piece. It's a continuous liquidity position with EPIC as the token and TRINI as the quote asset. At deploy time, the project owner sources ~$50 worth of TRINI from the `TRINI/USDC` pool to seed the cross-pair pool's quote side, so the pool can function as a real two-sided market from day one. (This is the only TRINI cost the project owner incurs.)

### 2.2 What happens in operation

In day-to-day operation, two flows interact:

**Flow A: External pair asset moves.** WETH, cbBTC, and CLANKER all have market prices that move on external venues. When any of them moves, the corresponding `EPIC/<asset>` pool's implied USD price for EPIC drifts. Arbitrageurs close the spread by buying EPIC from the cheaper pool and selling to the more expensive pool. This generates buy fees on the buy-side pool (paid in the quote asset, sent to the project's treasury) and burn-fees on the sell-side (paid in EPIC, sent to the burn address).

**Flow B: Organic project trading.** When a real user buys or sells EPIC on the `EPIC/USDC` pool, they create a temporary spread between USDC and the other pools. Arbs equilibrate. Same fee/burn dynamic.

The cross-pair `EPIC/TRINI` pool participates in both flows, but its quote asset price is **dynamic** — it's set by the current state of the `TRINI/USDC` pool, which lives in Trinity's own ecosystem. So when Trinity's own price moves (because of activity on `TRINI/USDC`), every project's `EPIC/TRINI` pool sees the move and arbs accordingly. Conversely, when arbs source TRINI to inject into a cross-pair pool, that buying pressure is real and shows up on `TRINI/USDC`.

### 2.3 The asymmetric flow that drives the lockup

Here is the key observation: **when a project has more buy volume than Trinity itself**, the project's USDC pool pumps. Arbs flow to equilibrate all the other EPIC pools, including the cross-pair pool. To bring the cross-pair pool's tick up, arbers must **buy EPIC from it**, which means **they pay TRINI in**. The pool absorbs TRINI.

Where does the arber's TRINI come from? They source it from the open market — specifically, the `TRINI/USDC` pool, which is the deepest TRINI venue. So a single arb cycle involves three legs:

1. **Buy TRINI from `TRINI/USDC` pool** (paying USDC) — pumps TRINI's price up
2. **Buy EPIC from `EPIC/TRINI` cross-pair pool** (paying TRINI) — locks TRINI in this pool
3. **Sell EPIC to `EPIC/USDC` pool** (receiving USDC) — closes the spread

After this cycle:
- `TRINI/USDC` pool has more USDC, less TRINI → Trinity's price has risen
- `EPIC/TRINI` pool has more TRINI, less EPIC → TRINI is now sitting in this pool (locked)
- `EPIC/USDC` pool has more EPIC, less USDC → its tick has come back down toward equilibrium
- The arber has earned the spread minus fees

**Both effects on Trinity are positive.** The price rises (durable, because the trade actually happened) and TRINI inventory accumulates inside the cross-pair pool (semi-durable, because the lock holds as long as the asymmetry continues).

### 2.4 What about quiet projects?

If a project never gets any organic activity, it never pumps its USDC pool, no asymmetric flow gets created, and the cross-pair pool sits inert. **Quiet projects don't lock any TRINI**. They also don't generate fee income — but that's the project's problem, not Trinity's. The launcher is unaffected.

This is the crucial property: **Trinity scales only with successful projects, never with failed ones**. There's no downside to listing dud projects — they just don't move the needle. The flywheel only spins when at least some projects are active.

---

## 3. Simulation methodology

We built a year-long simulator (`scripts/simulate-launcher.mjs` in the EPIC repo) that runs the full system over 365 daily timesteps. Key parameters:

- **Total supply** for both TRINI and each project's token: 100B
- **Launch FDV**: $1,000 (i.e., $1e-8 per token)
- **Top FDV** (range ceiling): $100M
- **Pool architecture**: continuous concentrated liquidity positions, one per pool. **No bands.** All committed tokens contribute to L at every price point in the range.
- **External pair asset volatility** (annualized, applied to WETH/cbBTC/CLANKER):
  - WETH: 60% (representative of recent ETH vol)
  - cbBTC: 55%
  - CLANKER: 150% (memecoin-tier)
- **Daily drift on pair assets**: 0 (true crab market)
- **Organic trading**: 50/50 buy/sell, distributed across multiple small daily trades. Volume per project varies by scenario.
- **Trinity organic volume**: $50/day across all scenarios (modest, constant baseline so we can isolate the launcher effect)

### 3.1 Two corrections from earlier model versions

Two bugs in earlier simulator versions inflated the headline numbers. Both have been fixed; the numbers in this section are honest:

**The TRINI-mirror.** Originally the arb engine operated on each project's pools independently, without modeling the secondary effect on Trinity's own pool. When an arb cycle absorbed TRINI into a cross-pair pool, the simulator didn't realize the arber had to source that TRINI from somewhere. The fix: after each project's arb round, measure the change in cross-pair TRINI inventory (Δ) and apply a corresponding trade on the `TRINI/USDC` pool (buy if Δ > 0, sell if Δ < 0), iterating until the system stabilizes within each daily step.

**The sell-cap bug.** The organic trade generator capped sell sizes to 1% of the pool's in-band EPIC inventory, which sounded like a safety check but actually created systematic buy bias — sells couldn't keep up with buys at the same dollar size. With nominally 50/50 trades, the actual flow was more like 50/0.6, drifting prices upward over time. Removing the cap (the swap function already handles boundary conditions) restored true crab-market behavior.

**The earlier version of this whitepaper claimed a "+58% TRINI lift" from the launcher in the 6-project scenario. That number came out of the sell-cap bug. The corrected numbers below tell a more nuanced story: the launcher works, but only at high volume tiers, and the marginal lift at realistic volumes is much smaller than that.**

### 3.2 The honest framing

We don't know what volume real projects will see. Nobody does. Rather than picking a single "realistic" number and building a story around it, this section shows the same scenario at four volume tiers — **$5/day, $50/day, $500/day, $5000/day per project** — so any prospective deployer can compare their actual expected volume against our data and form their own forecast.

### 3.3 Scenarios run

For each volume tier we run two configurations:

- **Set A (per-project economics)**: 1 project at that volume, with the cross-pair pool
- **Set B (launcher effect)**: 6 projects all at that volume, with cross-pair pools

Plus a **baseline** (Trinity standalone, no launcher) and a **realistic mix** scenario (6 projects at varied volumes 10-500/day) for context.

All scenarios use deterministic RNG seeds for reproducibility.

---

## 4. Results

### 4.1 Per-project economics by volume tier (Set A)

What does ONE project earn at each volume tier?

| Vol/day | Project price (× launch) | Project treasury | Project burns | TRINI locked | TRINI lift |
|---:|---:|---:|---:|---:|---:|
| $5 | 1.10× | $20 | 1.79B | 0 | none |
| $50 | 3.34× | $147 | 9.40B | 0 | none |
| $500 | 13.10× | $1,467 | 29.46B | 948M ($32) | none |
| $5,000 | **1,698×** | **$15,530** | 17.28B | 139M ($1,818) | **+1,300× TRINI saturates** |

**Reading this table**:

- **At $5/day**, the project earns essentially nothing ($20/year). The pool barely moves. Burns are real but small. The launcher cross-pair does nothing because volume is below the threshold for arb activity.
- **At $50/day**, treasury grows to $147/year — covers gas and some maintenance. Burns reach ~9% of supply over the year. The cross-pair still doesn't fire.
- **At $500/day**, the project starts working as a real income stream — $1,467/year treasury, meaningful price action (13.1× launch). The launcher mechanism finally fires, locking ~$32 of TRINI.
- **At $5,000/day**, the project effectively graduates: 1,698× launch price, $15.5k/year treasury. But the system runs through TRINI's entire range and the cross-pair pool fully drains as TRINI saturates at the top. **This is a regime where the launcher's $1e-8 → $1e-3 range was too narrow** — by the time a project is doing $5k/day, the curve is fully consumed. We'll need to think about wider ranges or graduation mechanisms for top-tier projects.

### 4.2 Launcher effect at each tier (Set B — 6 uniform projects)

What does TRINI earn when 6 projects are all at the same volume tier?

| Vol/day per project | Total launcher vol | TRINI final price | TRINI treasury | TRINI locked (USD) | Trinity uplift over baseline |
|---:|---:|---:|---:|---:|---:|
| Baseline (no launcher) | $0 | 3.46× | $87 | $0 | — |
| $5 × 6 = $30 | $30 | 3.25× | $94 | $3 | **−6%** (noise) |
| $50 × 6 = $300 | $300 | 3.07× | $97 | $27 | **−11%** (noise) |
| $500 × 6 = $3,000 | $3,000 | **15.60×** | $148 | $1,072 | **+351%** |
| $5,000 × 6 = $30,000 | $30,000 | **99,998×** | $2,242 | $0 | **system pinned at top** |

**Reading this table**:

- **Below $500/day per project**, the launcher's effect on Trinity is in the noise band. Tiny perturbations from the cross-pair arb activity nudge Trinity slightly down rather than up — it's effectively zero with a small amount of statistical drift in either direction.
- **At $500/day per project** (so $3,000/day across 6 projects, or roughly 50× Trinity's own organic activity), the launcher fires. Trinity's price multiple grows from 3.46× to 15.60× (a 4.5× lift), treasury grows ~70%, and ~$1,072 of TRINI accumulates locked across the cross-pair pools.
- **At $5,000/day per project**, the system effectively detonates. Trinity's price ends at the top of its range (the position has been fully crossed). The cross-pair pools are drained because TRINI is now too valuable to lock. **This regime suggests Trinity needs a wider range than the projects it backs** — currently they're identical at $1e-8 → $1e-3, but Trinity should probably go to $1e-2 or $1e-1 at the top.

**The launcher mechanism only meaningfully fires when total launcher activity exceeds Trinity's own organic activity by ~50× or more.** Below that threshold, the cross-pair arb signals are too small to drive sustained TRINI buy pressure on `TRINI/USDC`.

### 4.3 Realistic mixed-volume scenario

The scenario most likely to resemble real-world usage: 6 projects with varied trajectories, mostly modest, one breakout.

| Project | Vol/day | Price (× launch) | Treasury | Burned | Side reserves | Locked TRINI |
|---:|---:|---:|---:|---:|---:|---:|
| ALPHA | $10 | 3.30× | $67 | 2,479M | $208 | 35M |
| BETA | $30 | 4.17× | $116 | 3,812M | $287 | 159M |
| GAMMA | $50 | 3.68× | $157 | 7,545M | $236 | 65M |
| DELTA | $100 | 4.78× | $311 | 8,409M | $344 | 230M |
| EPSI | $200 | 3.49× | $599 | 21,898M | $221 | 52M |
| ZETA | $500 | 4.99× | $1,472 | 33,798M | $359 | 256M |
| **TOTAL** | **$890** | — | **$2,722** | 78B (78% of supply burned) | $1,655 | **798M ($25)** |

| | | |
|---|---:|---:|
| TRINI final | 3.16× launch | (vs 3.46× baseline) |
| TRINI treasury | $101 | (vs $87 baseline, +16%) |
| TRINI lift | **−9%** | within noise |

**This is the sobering picture.** With realistic mixed volumes — even when one project (ZETA) is doing $500/day and the rest are quieter — the launcher's effect on Trinity is essentially noise. The 6 projects collectively earn $2,722/year in treasury fees and burn 78% of their committed supply. **The projects do well; Trinity barely benefits.**

This is because the launcher mechanism requires *aggregate* asymmetric flow against Trinity's own activity. One single ZETA at $500/day isn't enough — you need either many ZETA-tier projects, OR a single dominant project doing $5,000+/day.

### 4.4 Where the launcher actually helps

Synthesizing the data above, the launcher's value to Trinity falls into three regimes:

| Total launcher activity | Effect on Trinity | What it means |
|---|---|---|
| **< $300/day combined** | None (noise) | Trinity gets no measurable benefit. The mechanism is below its activation threshold. |
| **$300–$3,000/day combined** | Modest | TRINI lift: 0–10%. Locked TRINI: $0–$50. Real but small. |
| **$3,000–$30,000/day combined** | Meaningful | TRINI lift: 50%–500%. Locked TRINI: $1k–$10k. The mechanism is firing. |
| **> $30,000/day combined** | Saturates | System runs through the full range. Need wider range or graduation logic. |

**The honest summary**: a Trinity launcher that only attracts very small projects (~$50/day each, even if you have many of them) won't see much benefit at the Trinity layer. The projects themselves still earn — just not much, and not enough cross-pair flow accumulates to materially move Trinity. The launcher needs **at least one breakout-tier project (~$500+/day) AND several supporting projects** to really make Trinity's price work as a backbone token.

**The case for building the launcher anyway**: the downside is bounded. If projects are quiet, Trinity is unaffected — quiet projects neither help nor hurt Trinity. The launcher adds optionality on the upside without taking anything away on the downside. You're betting that *some* project, eventually, will hit $500+/day, and when one does, Trinity captures that beta.

---

## 5. Why it works

The intuition is closer to how Curve's CRV / veCRV mechanics work than to a traditional bonding curve. With Curve, the value of CRV comes from being the gauge token across many pools — pool deployers and stablecoin issuers buy CRV to vote for emissions, and that buying creates durable demand for CRV regardless of any individual stablecoin's success.

The launcher mechanism here is similar in spirit but uses arb routes instead of governance. Each project's deployment commits TRINI to a position that *must* hold inventory to function. As project trading creates arb opportunities, arbers route TRINI through these positions, pumping its price along the way. The aggregate effect across N projects is roughly N times the effect of a single project (for projects of similar size).

**Critically, the design has four regimes** (see section 4 for the data backing each one):

| Regime | Aggregate launcher flow | Mechanism | Trinity outcome |
|---|---|---|---|
| **No launches** | $0/day | Trinity functions as a normal token. | Baseline. |
| **Quiet launches** | < $300/day | Inert cross-pair pools, arb activity below threshold. | No harm, no benefit. |
| **Goldilocks** | $3,000–$30,000/day | Asymmetric flow drives sustained TRINI buy pressure. | Substantial price lift + locked inventory. |
| **Saturated** | > $30,000/day | System runs through the full range. | Trinity hits the price ceiling, cross-pair pools drain. |

**There's no scenario where adding more launches *hurts* Trinity at the protocol level.** The downside floor is "no benefit, no harm." Even quiet projects don't extract from Trinity; they just don't contribute. The launcher adds optionality on the upside without taking anything away on the downside.

---

## 6. Limitations and risks

We're being deliberately honest about what the model doesn't capture and where the design breaks down.

### 6.1 Locking is not permanent

The cross-pair pools are **bidirectional market makers**, not vaults. The TRINI inventory accumulates when project flow is asymmetric in TRINI's favor. If a project later experiences sustained net selling (organic users dumping), arbs flow in reverse and the locked TRINI gets released back into circulation. The locking is **stable as long as the launcher ecosystem has at least some active projects with net buy pressure**. It's not a hard 4-year veCRV-style commitment.

This is mostly fine for the design's stated purpose — the goal is for Trinity to capture value from launcher activity, not to enforce permanent supply destruction. If you want permanent locking, you'd need a separate vault contract on top, which isn't in the current design.

### 6.2 The model assumes idealized arb behavior

Real arbitrageurs face gas costs, MEV competition, bridge frictions, and the simple fact of having to notice the spread in the first place. The simulator assumes spreads above the fee floor are always closed instantly and completely. In practice, arbs are slower and more expensive than this. **For very small projects, arb cycles below ~$5–10 in profitable spread won't get noticed by professional MEV bots and will just sit there.** This means the early-stage launcher income is somewhat overestimated by the model.

The flip side: as the launcher grows and pool sizes increase, arb attention scales up too. Pools that consistently produce $20+ arb opportunities get watched.

### 6.3 The TRINI/USDC pool is the load-bearing assumption

Trinity's whole value capture story depends on `TRINI/USDC` being the canonical source of TRINI for arbers. If most TRINI liquidity migrates elsewhere (a competing DEX, a CEX listing, etc.), the buy pressure from arb sourcing fragments and the price impact on `TRINI/USDC` shrinks. Trinity needs to either *be* the deepest TRINI venue or accept that the launcher backbone effect will be diluted.

### 6.4 Bear markets unwind the lockup

In a sustained bear market for Trinity itself (e.g., the launcher narrative breaks, big holders dump on `TRINI/USDC`, price drops), the cross-pair pools' implied USD price for EPIC drops too. Arbs run in reverse — they BUY EPIC from cross-pair pools (paying TRINI which they then dump on `TRINI/USDC`). **This amplifies Trinity dumps**, the same way the lockup amplifies Trinity pumps.

The launcher mechanism is a directional amplifier for Trinity's price action, not a stabilizer. Holders should understand this asymmetry. In practice, the floor is set by the project ecosystem's aggregate organic demand — even in a Trinity drawdown, projects with healthy organic flow will keep the cross-pair pools partly populated.

### 6.5 The project ecosystem must be curated

Anyone can pair their token with any quote asset on Uniswap V4. To make Trinity *the* default launcher quote, there needs to be a real product that projects opt into — a deploy script, a frontend, a brand, curation. Without curation, the launcher backbone effect doesn't materialize because there's no concentration. **Trinity-as-a-launcher is a product, not a passive token property.**

---

## 7. Design recommendations

Given everything above, here's what we're going to build next:

### 7.1 New hook contract

The current TrinityHookV6 / V7 / EPIC hooks all use discrete liquidity bands. They leak. They go away. The new hook is **TrinityHookV8**, which:

1. **Uses a single continuous concentrated liquidity position per pool.** No bands. No transitions. Standard V4 mechanics.
2. **Takes parameterized symmetric fees** (1%/2% defaults but configurable per deploy, capped at 10%) before the swap touches the AMM, via `BeforeSwapDelta`.
3. **Blocks external LP** — `BEFORE_ADD_LIQUIDITY` reverts unless sender is the hook itself. Only the hook can mint into the pool, so curve depth is fully controlled by the deployer.
4. **Supports both single-sided and two-sided seeding** — the same `addLiquidity()` function handles initial seed, additional seeding, and mid-band positions, all by reading the hook's current token balance and computing max liquidity from current price.
5. **Is parameterized** so any project can deploy a copy with their own token + fee + range + owner. No more hardcoded constants.
6. **Has no `afterSwap` rebalancing** — V6/V7 used afterSwap for band transitions, V8 has nothing to rebalance, saving ~3000 gas per swap.

TrinityHookV8.sol is checked in at `trinity/contracts/TrinityHookV8.sol` and compiled successfully through forge in the ArbMe contracts workspace. **Deployed bytecode size: 9.5KB** (well under the 24KB Spurious Dragon limit). 31 functions on the ABI.

### 7.2 Launcher deploy script

A single deploy script that takes a project's parameters (token address, total supply, FDV range, initial seed budget) and deploys the full 5-pool set:

- Mint the standard pools
- Source the cross-pair seed amounts (~$50 of each quote asset, including TRINI for the cross-pair pool)
- Inject seeds to make all pools two-sided and functional from day 1
- Verify on-chain state and report deployment addresses

### 7.3 Trinity stays live

The current TrinityHookV6 is going to be **replaced**, not removed. We'll drain the existing band-based pools (the JSONs to do this are sitting in `epic/scripts/teardown/teardown-trini.safe.json` from a few days ago) and redeploy fresh continuous-position pools using the new hook. The TRINI ERC20 contract and the staking hub stay untouched.

### 7.4 EPIC is the first launch

EPIC will be the first project to deploy on the new infrastructure, including the EPIC/TRINI cross-pair pool. This serves as a real-money test of the launcher mechanism. If successful, additional projects can follow.

---

## 8. What this isn't

**This isn't a yield farm.** Trinity holders don't earn from a fixed emission schedule. They earn from organic launcher activity, which is highly variable and depends on whether real projects use the system.

**This isn't a get-rich scheme.** The numbers in section 4 show meaningful returns, but they assume sustained launcher activity. In a year with no launches, Trinity is just a normal token.

**This isn't a permanent lockup.** As discussed in 6.1, the lockup is conditional on continued asymmetric flow. It's an inventory management mechanism, not an escrow.

**This isn't a substitute for project utility.** Each project still needs its own reason to exist. The launcher just provides better economics for the founder than the standard "sell your bag" model.

---

## 9. Open questions for next iteration

- **Trinity needs a wider range than the projects it backs.** The simulation showed that at $5000/day per project (Set B / saturated regime), the system runs through Trinity's entire $1e-8 → $1e-3 range and the cross-pair pools fully drain. Trinity should probably deploy with a range like $1e-7 → $1e-2 (still 100,000× but starting at $10k FDV and topping at $1B FDV) so it has room to absorb breakout-tier launcher activity without saturating. Project ranges can stay at $1e-8 → $1e-3.

- **What's the optimal cross-pair allocation?** We tested 1% of supply. Higher allocations would lock more TRINI per project but also expose the project to more TRINI-correlated price action. The right trade-off probably depends on project size and intended TRINI exposure.

- **Should the cross-pair pool use a different fee than the other side pools?** We've used 2% symmetric. A higher sell fee (more burn) might compound the lockup faster but reduce arb frequency.

- **Multi-launcher backbone?** Could the same project pair with TRINI *and* another launcher backbone token simultaneously? The math says yes, but the design implications need thinking through.

- **Time-decay on cross-pair allocations?** Could the cross-pair allocation be retired to a vault after some period (e.g., one year), turning the soft lock into a hard lock for stale projects? Worth modeling.

- **How to handle "graduation"?** When a project's main USDC pool exits the top of its range, the curve effectively retires. Should the hook auto-detect this and unlock external LP (graduate the project to a normal Uniswap pool)? Or stay locked forever? This affects how we'd handle a hypothetical $5000/day breakout project.

- **What happens with realistic non-uniform external markets?** The simulator assumes `TRINI/USDC` is the *only* TRINI venue. In reality there will be at least a few others (other DEXes, eventually CEXes if anything works). Trinity's value capture is diluted by external TRINI liquidity. We should model this with a "TRINI external sink" parameter.

These are good problems to have. They imply a working mechanism, not a broken one.

---

*Generated from `scripts/simulate-launcher.mjs` in the [EPIC repo](https://github.com/) (private). Source data in `scripts/launcher-results.json`. The simulation methodology and core assumptions are documented in the script comments.*
