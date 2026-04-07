# Trinity V5 vs V6 — Comparison

## One-Line Summary

V5 is a prototype where the core mechanism (band rebalancing) doesn't work.
V6 is a redesign where it does.

## The Critical V5 Bug

V5's LP was seeded by an external `LPSeeder` contract. Uniswap V4 keys LP
positions by `(owner, tickLower, tickUpper, salt)`. The LPSeeder was the owner,
not the hook. When the hook tried to rebalance — removing LP from one band to
add to the next — it couldn't. The PM rejected the call because the hook didn't
own the position.

Result: all 900M TRINI of LP sat permanently in band 0. The "15-band bonding
curve" was actually a single concentrated LP position. Price bounced around
inside band 0's range and that was it.

## What V6 Changes

### 1. Hook Owns Its LP (CRITICAL fix)

V5: `LPSeeder` → `PM.modifyLiquidity()` → position owned by LPSeeder.
V6: `hook.ownerSeedBand()` → `hook.manager.unlock()` → `hook.modifyLiquidity()` → position owned by hook.

The hook calls `manager.unlock()` itself, so it's `msg.sender` when
`modifyLiquidity` is called. The position is keyed to the hook's address.
Rebalancing can now actually remove and re-add LP.

### 2. Emergency Withdrawal Works (HIGH fix)

V5: `withdrawLP` called `manager.modifyLiquidity()` directly — outside an
unlock context. Always reverted.

V6: `emergencyWithdrawLP` wraps the call in `manager.unlock()` with a callback.
The multisig can actually recover LP if something goes wrong.

### 3. exactOutput Fee Bypass Closed (HIGH fix)

V5: `beforeSwap` returned zero delta for `amountSpecified >= 0`. Anyone could
use `SWAP_EXACT_OUT_SINGLE` to trade fee-free.

V6: `beforeSwap` reverts with `ExactOutputNotSupported()`. After graduation,
exactOutput is allowed (no fee in graduated mode anyway).

### 4. Multi-Band Transitions (HIGH fix)

V5: `_checkAndRebalance` used a single `if` — one band per swap. A large
price move left the hook desynchronized for multiple subsequent swaps.

V6: Bounded `while` loop, max 5 steps per swap. Covers 99% of realistic
price moves in a single transaction.

### 5. Overflow Fix in Liquidity Math (HIGH fix)

V5: `num * uint256(sqrtUpper)` → `2^250 * 2^160 = 2^410` → silent uint256
overflow. Wrong liquidity values, less LP deployed than intended.

V6: Divide-first pattern — `(amount0 * sqrtCurrent / diff) * sqrtUpper >> 96`.
Intermediate products stay within uint256. Small precision loss accepted as
trade-off.

### 6. External LP Blocked (NEW in V6)

V5: `beforeAddLiquidity` returned success for everyone. External LP diluted
the hook's positions and desynchronized band tracking.

V6: `beforeAddLiquidity` reverts for non-hook callers during bonding curve
phase. Only the hook manages LP. After graduation, external LP is allowed.

### 7. Graduation (NEW in V6)

V5: No graduation concept. Pools are bonding curves forever.

V6: No graduation. Curves are permanent. The audit found auto-graduation
was exploitable via flash loans. An owner-only version was considered but
cut — the curves are designed to never finish. The multisig can use
`emergencyWithdrawLP` to reposition LP if needed.

### 8. Curve Design (NEW in V6)

V5: Uniform 3,400-tick bands. Linear-ish curve. Same allocation per pool.

V6: Variable band widths with deceleration pattern:
- Shared steep ignition band (1,200 ticks) — price discovery
- Each pool decelerates at its own rate
- USDC: fast decel, deep (450M TRINI) — the stable anchor
- WETH: medium decel (297M TRINI) — the relay
- ChaosLP: slow decel, thin (153M TRINI) — the volatility engine
- $25K starting FDV (was $100K in V5)

## Architecture Comparison

```
V5 Flow:
  deploy → LPSeeder seeds band 0 → hook can't touch it → band rebalancing is a no-op
  beforeSwap: fee extraction (but exactOutput bypasses it)
  afterSwap: single-step rebalance (doesn't actually work)

V6 Flow:
  deploy → hook seeds band 0 via ownerSeedBand → hook owns the position
  beforeSwap: fee extraction + exactOutput blocked
  afterSwap: multi-step rebalance (actually works)
  No graduation — curves are permanent
```

## Risk Profile

| Risk | V5 | V6 |
|---|---|---|
| LP stuck forever | YES (LPSeeder owns it) | NO (emergencyWithdrawLP works) |
| Fee bypass | YES (exactOutput) | NO (reverts) |
| Band rebalancing | BROKEN (can't manage LP) | WORKS (hook owns positions) |
| External LP dilution | POSSIBLE | BLOCKED during bonding |
| Flash-loan graduation | N/A (no graduation) | N/A (no graduation — removed) |
| Multisig rug | LIMITED (can't touch LP) | POSSIBLE (emergencyWithdrawLP exists) |
| Cross-pool TRINI leakage | N/A (rebalancing broken) | ACCEPTED (auto-redistributes TRI) |

## What Didn't Change

- Fee model: 1% on input. Buy → multisig. Sell → burn to 0xdead.
- Hook permissions: BEFORE_SWAP, BEFORE_SWAP_RETURNS_DELTA, AFTER_SWAP
  (V6 adds BEFORE_ADD_LIQUIDITY).
- Token: TrinityTokenV6 ("Trinity", "TRINI") — 1B supply, standard OZ ERC20.
- Staking: ChaosLPHub + RewardGauge (unchanged).
- Frontend: TradePanel via Universal Router (same swap encoding).
