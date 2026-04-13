---
title: "Cofounder Briefing"
date: "2026-04-10"
summary: "Internal briefing document for cofounder onboarding — what Trinity is, how it works, where it's going."
---

# Trinity: Cofounder Briefing

**What it is:** A public-facing lab for tokenomics R&D that helps small projects and communities launch tokens that actually serve their goals. Life-affirming DeFi at small scale.

**What we're selling:** The bonding curve infrastructure we've built, the design methodology behind it, and the track record of shipping working experiments on Base mainnet.

---

## The One-Paragraph Version

Trinity is a Uniswap V4 hook framework that lets anyone deploy a token with bonding curve liquidity across multiple quote assets (USDC, WETH, BTC, whatever) with customizable fee structures including asymmetric buy/sell fees. The mechanism creates permanent liquidity, generates arbitrage-driven revenue, and allows fine-tuned control over price dynamics. We've deployed it four times in increasingly refined forms (V4 → V5 → V6 → V7) and the latest version handles single-pool experiments, asymmetric fees, and multi-asset arb surfaces. The goal of the lab is to keep iterating on the framework and offer it as a launch kit for small projects that want real, honest token economics instead of extractive VC-backed launches or pure memecoin speculation.

---

## What's Actually Built

### The Core Mechanism (V6 and V7 hooks)

A Uniswap V4 hook contract that manages LP positions as **discrete bands approximating a bonding curve**. When someone swaps, the hook:

1. Extracts a configurable fee from the input (before the AMM runs)
2. Routes the fee — buy fees to treasury, sell fees to burn (or anywhere else)
3. Automatically rebalances LP to the next band when price crosses boundaries

The bands are one-sided liquidity positions seeded at deploy time. As price moves through them, the curve progressively gets deeper, creating a built-in support structure. There's no graduation event — the curves are permanent infrastructure.

**V6** supports multiple pools per hook (3 in current deployment: USDC, WETH, ChaosLP) with a single fee rate. **V7** is the single-pool-per-hook evolution that supports asymmetric buy/sell fees and per-pool customization. V7 is the production version we'd offer to new projects.

### Currently Live on Base Mainnet

**TRINI token** — 1B supply, deployed as the first project using the framework.

**V6 hook** managing USDC (1% fee), WETH (1% fee), and $CHAOSLP (retired, liquidity withdrawn).

**V7 hooks**: TRINI/Clanker (5% fee) and TRINI/WETH (5% fee) — newer single-pool architecture.

**Staking Hub** + WETH and $CHAOSLP reward gauges — TRINI holders can stake to earn rewards distributed from protocol fees.

All contracts verified on Basescan. All tradeable on Uniswap V4 pools. Listed on GeckoTerminal. Frontend at trinity-prototype.pages.dev.

### The Second Deployment: $EPIC

Using the same V7 framework, we deployed $EPIC (epicdylan.com's site coin) with 10 pools across 4 quote assets (USDC, WETH, cbBTC, Clanker) and 4 distinct fee structures including a ratchet design (4% buy / 16% sell) that creates a one-way value accumulation mechanism. This is the proof that the framework is reusable — same contracts, new token, different economic configuration, no custom engineering required.

---

## The Design Philosophy

### Why This Exists

Most token launches do one of two things:
- **Extractive**: VC-backed projects with hidden allocations, vesting cliffs, insider advantages
- **Degenerate**: Pure memecoins with no mechanism, fully dependent on hype cycles

There's a missing middle: projects that want real economic infrastructure — permanent liquidity, fair launches, transparent mechanics, honest revenue models — but don't have the resources to build it from scratch.

Trinity exists because that middle should exist. A small community running an app, a creator with an audience, a hobbyist protocol — they should be able to launch a token with the same kind of mechanism sophistication as a major DEX, without having to hire a team of Solidity engineers.

### Core Principles

**Mechanism > Marketing.** Every choice is documented and defensible. The fees are visible. The math is published. There's no "trust the team" — there's "read the code."

**Permanent infrastructure.** Bonding curves don't graduate. They don't migrate. They don't get deprecated. The LP bands are there forever as support, regardless of price level.

**Ecosystem compatibility.** We use real Uniswap V4 hooks, not custom AMM accounting. This means every indexer sees the pools, every aggregator can route through them, every bot can arb them. No walled gardens.

**Asymmetric fees as a design tool.** Buy fees and sell fees don't have to be equal. This unlocks design space: ratchets (easy in, hard out), burn engines (high sell fees → deflationary), yield streams (buy fees → stakers), and more.

**Small is beautiful.** The target user isn't a fund, it's a person or a small community. Total launch cost is under $20 in gas. No team allocation needed. No presale. No VC round.

---

## What the Lab Does

### 1. R&D on Tokenomics

Each new token deployed is an experiment. We document what we tried, what worked, what didn't, and update the framework. The V4 → V7 progression already shows this: each version fixed issues from the previous one and added new capabilities.

Open research questions we're working on:
- Optimal band shapes for different volatility profiles
- Asymmetric fee tuning (when does a ratchet help vs hurt?)
- Multi-asset arb surfaces (how many quote assets is optimal?)
- Oracle-adjusted tick bases (can we eliminate the "WETH pool drains on ETH rally" problem?)
- Staking-free fee distribution (access-based token utility instead of yield)
- Legal/regulatory framing that keeps projects on solid ground

### 2. Launch Infrastructure for Small Projects

The framework is ready. What we need to build around it:
- **Launch wizard** — a web interface where someone describes their project (token name, supply, quote assets, fee model) and gets a deployable contract + frontend
- **Template library** — "ratchet," "burn engine," "access token," "community coin" templates with tuned parameters
- **Deployment service** — we run the deploy, we handle verification, we seed the curves
- **Post-launch support** — monitoring, rebalancing, documentation, help articles

### 3. Public-facing Documentation

The project itself becomes the example. People visit trinity-prototype.pages.dev (and soon epicdylan.com/blog) to see:
- How the mechanisms actually work
- What choices we made and why
- What the tradeoffs look like in practice
- Real numbers from real deployments

---

## The Revenue Model

This is the elegant part. The same mechanism that generates value for the lab also creates aligned incentives across every participant type.

**How the money flows:**

1. **Lab earns USDC** from the 1% USDC pool fees. This is operating revenue — covers development, infrastructure, salaries, whatever the lab needs to keep running. Collected automatically on-chain, visible on Basescan, no custodian required.

2. **Stakers earn WETH and Clanker** from the WETH and Clanker pool fees. Every time those pools generate arbitrage activity, the buy-side fees accumulate as WETH and Clanker. The staking hub distributes those to TRINI stakers proportionally.

3. **Burns happen on every sell.** Across all pools, sell-side fees burn TRINI to 0xdead. The supply only decreases over time, benefiting everyone who holds.

**Who stakes TRINI, and why:**

- **Partners** — projects that want us to build tokens for them make arrangements where they stake a minimum amount of TRINI for a minimum period. The stake aligns their interests with the lab's long-term health. Skin in the game for both sides.

- **Community members** — people who believe in the anti-PVP tokenomics thesis and want to support the lab's work. They're buying into the philosophy, and they get real yield (WETH, Clanker) for their support instead of nothing.

- **Speculators** — people who think they can earn more WETH from staking than the USD value they spent buying TRINI. This is a legitimate arbitrage over time: if the lab generates enough fee activity, the yield can exceed the entry cost. They're betting on adoption.

**Why this is a risk pool, not just staking:**

Every staker is committing TRINI to a contract for a period of time. During that period, they can't dump it. That removes sell pressure from the market. The more people stake, the less volatile the token becomes, the more reliable the revenue flow is for everyone.

Partners staking TRINI are effectively underwriting the project with their own capital. Speculators staking TRINI are bearing the holding risk in exchange for yield. Community members staking TRINI are expressing conviction and getting compensated for it. Everyone is taking the same action for different reasons, and everyone benefits if the lab succeeds.

The lab itself isn't just collecting fees — it's running the protocol that generates the fees, building the R&D that attracts new partners, and publishing the research that attracts new stakers. Everyone is on the same side of the table.

**The alignment forcing function:**

Partners can't dump their stake on speculators, because they've committed it. Speculators can't exit quickly without losing their yield accrual. Community members get paid for their patience. The lab gets working capital to fund development. Nobody wins at someone else's expense — everyone wins together, or nobody wins.

This is the anti-PVP structure in practice. Not a slogan.

---

## Legal Framing (Important)

We had a conversation earlier about the securities angle and it's worth surfacing here since it's central to how we pitch this.

**The challenge:** A token + staking yields + creator revenue + "expectation of profits" hits every prong of the Howey test. The SEC could characterize $TRINI (and similar lab-launched tokens) as unregistered securities offerings.

**What protects us:**

- Everything is on-chain, public, verifiable. No hidden allocations, no insider advantages, no off-chain promises.
- No presale, no VC round, no team token allocation. The lab buys its own TRINI through the same pools everyone else does.
- The staking rewards come from real protocol activity (pool fees), not inflation. There's no "yield from nothing."
- The tokens have utility beyond yield — access to lab services, governance in protocol decisions, ability to commission new token launches.

**What we need to do:**

- Work with a crypto-native securities lawyer to get formal clarity before we pitch to partners at scale. This is genuinely unsettled legal ground.
- Frame the token primarily as a commitment mechanism and governance tool, not an investment product.
- Never promise returns. Always describe yields as variable, not guaranteed.
- Consider jurisdiction — the lab might need to incorporate somewhere crypto-friendly.
- Be explicit about risks in all marketing.

This is one of the main things I want your help thinking through. The mechanism works. The legal framing is the hard part.

---

## What's Already In This Repository

```
trinity/
├── contracts/              — All smart contracts (V4-V7 hooks, token, deploys)
├── src/
│   ├── app/               — Next.js 16 pages (trade, stake, docs, blog)
│   ├── components/        — TradePanel, StakingPanel, Nav
│   └── lib/               — Contract ABIs, addresses, hooks
├── content/blog/          — Markdown blog posts (dev log)
├── public/                — Static docs (curves, implementation details)
├── functions/             — Cloudflare edge (Farcaster Snap)
└── temp/                  — Research notes (Farcaster integration, V4 work)
```

**Key contracts:**
- `TrinityHookV6.sol` — Multi-pool hook, 1% symmetric fees (current production)
- `TrinityHookV7.sol` — Single-pool hook, configurable fees (current experimental → production)
- `TrinityTokenV6.sol` — Standard ERC-20 (nothing fancy)
- `ChaosLPHub.sol` — Staking hub (reward distribution)
- `RewardGauge.sol` — Per-asset reward streams

**Key docs:**
- `README.md` — Quick overview + addresses
- `v6-design.md` — Design rationale, prior art, architecture
- `v6-audit.md` — Three-pass security review
- `launch.md` — The marketing narrative (arbitrage flywheel, fee engine)
- `v5-vs-v6.md` — What changed and why

---

## What Needs to Get Built Next

### Short Term (immediate priorities)

1. **Consolidation and cleanup**
   - Merge TRINI's blog style with the EPIC blog to share components
   - Unify the wallet connection across both sites
   - Pick ONE canonical docs site (TRINI's prototype site or a new lab site)

2. **Launch wizard MVP**
   - Form: token name, supply, quote assets, fee structure
   - Output: deploy script + verified contracts + seeded pools
   - Start with CLI version, web UI later

3. **Lab branding**
   - We need a name for the lab (Trinity? Different?)
   - Landing page explaining the offer
   - Example deployments (TRINI, EPIC) as case studies

### Medium Term

1. **Template library** — document 4-6 canonical tokenomics patterns
2. **Legal framework** — work with a crypto securities lawyer to publish a compliance guide
3. **Partnership outreach** — find 2-3 small projects who want to launch and work with them as pilot customers
4. **Tooling** — monitoring dashboard, simulation tools, backtesting

### Long Term

1. **Revenue model** — deployment fees? ongoing cut of protocol fees? subscription for monitoring tools? (needs discussion)
2. **Community** — turn the blog audience into an actual community of token designers
3. **Research publications** — write up what we've learned in a way that others can build on

---

## What I'd Want From You

Based on the split we agreed on (you sell, I build):

- **Sales narrative** — help me articulate why a small project would choose Trinity over launching a token on Clanker or Zora
- **Pilot projects** — find 2-3 early adopters who can launch on the framework and give us case studies
- **Legal clarity** — help us understand the compliance lane for offering this as a service
- **Brand** — naming, visual identity, positioning
- **Distribution** — who do we talk to, which conferences, which communities

I'll handle:
- **The tech** — contracts, frontend, deployment tooling, audits
- **The documentation** — blog posts, how-tos, case studies of our own launches
- **The experiments** — running R&D on the tokenomics side, publishing findings
- **The infrastructure** — keeping the existing deployments healthy, monitoring, upgrades

---

## Open Questions for Us to Decide Together

1. **Name and identity** — Trinity is the project name but also a specific token. For the lab, do we keep "Trinity" as the umbrella or pick something new?

2. **Positioning** — is this "bonding curves as a service," "tokenomics R&D lab," "anti-PVP DeFi for small communities," or something else entirely?

3. **First customer** — do we pitch an existing project we admire, or wait for inbound? How do we price the first deployment?

4. **Partner staking requirements** — when we work with a project, what's the minimum TRINI stake we ask for? How long does it lock? What's the tradeoff between high requirements (strong alignment) and low requirements (easier to onboard)?

5. **Timing** — when do we go public with the lab? Before or after another TRINI/EPIC-style launch?

6. **Legal entity** — do we incorporate? where? what jurisdiction makes sense for a tokenomics R&D lab? What's the partnership structure between us?

7. **Securities lawyer** — who do we talk to? How much is this going to cost? Is there a budget?

---

## Resources

**Live deployments:**
- Trinity: https://trinity-prototype.pages.dev (token: `0x17790eFD4896A981Db1d9607A301BC4F7407F3dF`)
- Epic: https://epicdylan.com (token: `0x003b9aC55a8575295e4BE4901AA1645CC2132369`)

**Code:**
- Trinity repo: https://github.com/ipfsnut/trinity-prototype
- Contracts in: `ArbMe/packages/contracts/src/trinity/` and `src/epic/`

**Blog posts explaining the work:**
- Trinity V7 deployment: https://trinity-prototype.pages.dev/blog/v7-two-new-pools
- Epic launch: https://epicdylan.com/blog/epic-launch

**Chain:** Base mainnet (Uniswap V4 PoolManager `0x498581fF718922c3f8e6A244956aF099B2652b2b`)

---

*This document is a snapshot. It's meant to give you enough context to have real conversations about direction. Everything here is up for debate.*
