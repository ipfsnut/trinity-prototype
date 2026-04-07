# Trinity — What It Is, What It Does, Why You Might Want Some

## The Short Version

Trinity is a token ($TRINII) that trades across three Uniswap V4 pools on Base.
Each pool has a different bonding curve shape. The price differences between
pools create arbitrage opportunities. Every arb trade pays a 1% fee. Those
fees go to stakers and the community treasury.

**It's a fee engine.** The token exists to generate trading activity. The
trading activity generates fees. The fees reward the people who believe in it
early enough to stake.

## How It Works

### Three Pools, Three Curves

TRINII trades against three assets: USDC, WETH, and $CHAOSLP. Each pool has a
custom bonding curve implemented as a Uniswap V4 hook — a smart contract that
manages concentrated liquidity positions across price bands.

The curves have different shapes:

- **USDC** — The anchor. Deep liquidity, slow price movement. This is where
  most people will buy. Your $50 buy barely moves the price.

- **WETH** — The middle ground. Moderate depth, moderate movement. ETH's own
  volatility adds interesting dynamics.

- **ChaosLP** — The wild one. Thin liquidity, steep curve. A $20 buy moves
  the price 8%. ChaosLP itself is a micro-cap token (~$2,600 MC), so it's
  inherently volatile. That volatility is the engine.

### The Arb Flywheel

Because the curves have different shapes, TRINII has different prices on
different pools at any given time. Arbitrage bots see this and trade:

1. Bot buys TRINI on the cheap pool (e.g., USDC — stable, lower price)
2. Bot sells TRINI on the expensive pool (e.g., ChaosLP — just spiked)
3. Each leg of the trade pays a 1% fee (2% total per cycle)
4. Fees go to the community treasury and stakers
5. The arb narrows the price gap — until the next trade widens it again

This happens continuously. Every time someone buys on any pool, the prices
shift, creating a new arb opportunity. Every arb generates fees. The fees
reward stakers.

### The Fee Model

Every swap pays a 1% fee on the input amount:
- **Buys**: 1% of the quote asset (USDC, WETH, or ChaosLP) goes to the
  community treasury (a Safe multisig).
- **Sells**: 1% of the TRINI input is burned (sent to 0xdead). This is
  deflationary — total TRINI supply decreases with every sell.

### Staking

Stake your TRINI to earn a share of the fee revenue. The treasury distributes
rewards to stakers proportional to their stake. More volume = more fees =
better staking yields.

## Numbers

- **Starting price**: $0.000025 per TRINI
- **Starting FDV**: $25,000
- **Total supply**: 1,000,000,000 TRINI
- **Pool allocation**: 450M (USDC), 297M (WETH), 153M (ChaosLP)
- **Treasury**: 100M TRINI
- **Chain**: Base (L2 — gas is ~$0.005 per swap)

## What's a V4 Hook?

Uniswap V4 introduced "hooks" — smart contracts that attach to pools and run
custom logic before or after swaps. Trinity's hook:

- Extracts 1% fees before each swap
- Manages LP positions across price bands
- Automatically rebalances liquidity as the price moves
- Blocks external LP from diluting the bonding curve
- Curves are permanent — no graduation, fees collect forever

This is live, verified Solidity on Base. The source code is public. The
contract has been through a triple-pass security audit.

## Risks — Read This

**This is a prototype.** It's experimental DeFi built by a small team. Here's
what you need to know:

1. **Smart contract risk.** The hook is custom code managing LP on Uniswap V4.
   V4 itself is relatively new. Despite a thorough audit, unknown bugs may
   exist. Don't put in more than you're comfortable losing entirely.

2. **Multisig trust.** The hook is owned by a multisig. The multisig can:
   - Graduate pools (removing the fee mechanism)
   - Emergency withdraw LP (recovering the hook's liquidity)
   - Update fee recipients
   - Withdraw tokens held by the hook
   
   The multisig cannot steal YOUR tokens — only the protocol's LP. But a
   compromised multisig could disrupt the protocol.

3. **Liquidity risk.** Early on, liquidity is thin. Large buys/sells will
   have significant price impact. The ChaosLP pool is intentionally thin —
   that's the design, not a bug.

4. **No guarantee of returns.** Staking yields depend on trading volume. If
   nobody trades, there are no fees. The arb flywheel only spins if there's
   organic activity to create price divergences.

5. **Token price risk.** TRINI starts at $0.000025. It could go lower. The
   bonding curve creates upward price pressure as more people buy, but it
   also means early sellers take a loss relative to later buyers.

## How to Buy

1. Connect your wallet to the Trinity app on Base
2. Pick a pool (USDC is recommended for most people)
3. Enter an amount
4. Approve + swap

The frontend uses Uniswap's Universal Router — standard V4 swap encoding.
Permit2 handles approvals.

Or just buy on any V4 aggregator that routes through Base pools.

## What Makes This Different

Most bonding curve tokens (pump.fun, Clanker, etc.) use a single pool with a
single curve. Trinity uses three pools with three different curves, creating a
permanent arb surface. The arb generates fees. The fees reward stakers.

Nobody else is doing this. The closest comparison is Bunni V2 (hook-managed LP)
or Doppler (bonding curve via LP slugs), but neither combines managed LP bands
with asymmetric fee extraction and multi-pool arb economics.

The academic foundation is sound: concentrated LP positions are mathematically
equivalent to bonding curve segments. A collection of positions at different
tick ranges IS a discrete bonding curve. We just have three of them with
different shapes.

## Known Issues — Full Transparency

The contract has been through two full audit cycles (6 independent passes
total). No critical or high-severity issues remain. Here's everything that
does remain, why it's there, and what it means for you.

### Medium Severity (2) — Accepted by Design

**Cross-pool TRINI sharing.** The hook manages three pools that all use TRINI.
When one pool rebalances its LP, leftover TRINI can get swept into another
pool's LP on its next rebalance. This means the TRINI distribution across
pools isn't perfectly isolated — it's more like a shared reservoir. We
accepted this because all three pools draw from the same TRINI allocation
anyway, and fixing it would require per-pool accounting that adds
significant complexity to a prototype. The quote-side tokens (USDC, WETH,
ChaosLP) are unique per pool and never cross-contaminate.

**Multisig trust.** The hook owner (a Safe multisig) can emergency-withdraw
LP, drain hook-held tokens, and update fee recipients. In
the worst case, a compromised multisig could rug the protocol's LP — not
your wallet, but the protocol's liquidity. This is inherent to the owner
model. Post-launch, we can add a timelock by transferring ownership to an
OpenZeppelin TimelockController (no contract changes needed). That would
give users a warning window before any owner action takes effect.

### Low Severity (5) — Edge Cases, Not Threats

**Fee rounding on dust swaps.** Swaps under 100 wei of input pay 0% fee
(integer division rounds to zero). Exploiting this would require thousands
of micro-swaps per block — the gas cost far exceeds the fee saved. Not
economically viable on any chain.

**Owner footguns.** The owner can seed a band with zero liquidity (marking
the pool as "seeded" without actual LP), drain tokens the hook needs for
rebalancing, or pass an invalid band index to emergency withdraw. These
are operator errors, not external attacks. The multisig operators know
the constraints.

**Theoretical integer cast.** An internal type conversion could wrap on
amounts exceeding 170 undecillion tokens. No token has remotely this much
supply. Not physically possible.

**Redundant state check.** `afterSwap` doesn't independently verify the
pool is registered, because `beforeSwap` already does — and `afterSwap`
can't fire if `beforeSwap` reverted. Belt-and-suspenders redundancy
wasn't added here since it costs gas on every swap for zero benefit.

**Negative delta edge case.** The emergency withdrawal handler assumes
Uniswap V4's PoolManager always returns non-negative deltas when removing
liquidity. This is correct for current V4 behavior. If the PoolManager's
semantics changed in a future version, this assumption would need
revisiting.

### What Was Fixed (Two Audit Cycles)

The contract started as V5, which had a critical bug: the hook couldn't
manage its own LP (positions were owned by a separate seeder contract).
V6 was a ground-up redesign. Across 6 audit passes, we found and fixed:

- Hook can't manage LP → hook seeds its own LP via `ownerSeedBand`
- Emergency withdraw broken → wrapped in unlock callback
- Fee bypass via exactOutput swaps → reverts during bonding curve
- Integer overflow in liquidity math → `FullMath.mulDiv` (full precision)
- Single-step band transition → bounded loop (up to 5 per swap)
- External LP dilution → blocked via `beforeAddLiquidity`
- Flash-loan forced graduation → graduation removed entirely
- No way to update fee recipient → `updateFeeRecipient` added
- Unchecked ERC20 transfers → safe transfer pattern
- Unvalidated band configuration → contiguity + ordering checks
- Stale price in liquidity computation → reads actual `sqrtPriceX96`
- Re-seed after withdraw could fail → handles accrued fee credits

Full details: `contract-audit.md` (V5 audit), `v6-audit.md` (V6 audit).

## Links

- Contract source: `contracts/TrinityHookV6.sol`
- Audit (V5): `contract-audit.md`
- Audit (V6): `v6-audit.md`
- Design: `v6-design.md`
- V5 comparison: `v5-vs-v6.md`
- Curve visualization: `curve-chart.html`
