# Trinity V6 Hook Design

## Context

V5 is live on Base with 3 pools (~$93K TVL, ~$344 volume day 1). A thorough
audit (`contract-audit.md`) found 1 critical, 5 high, and 5 medium issues.
The most important: the hook cannot manage the initial LP because position
ownership belongs to the LPSeeder, not the hook. Band rebalancing is
structurally non-functional.

V6 is a clean redeploy that fixes every audit finding while preserving the
core concept: **discrete LP bands approximating a bonding curve, with
automatic rebalancing and asymmetric fee extraction.**

---

## Prior Art

A FOSS literature review found no existing project that combines all five of
Trinity's characteristics. The closest projects and what we can learn from them:

| Project | License | Closest Feature | Key Takeaway for V6 |
|---|---|---|---|
| **Bunni V2** (Timeless) | MIT/AGPL | Hook-owned LP + rebalancing | Use ERC-6909 position ownership model. RebalanceLogic as separate library. Was exploited ($8.4M) — LDF logic bugs. Keep our math simple. |
| **Doppler** (Whetstone) | BUSL 1.1 | Bonding curve via LP "slugs" | 3-slug architecture (lower/upper/discovery). Epoch-based rebalancing in beforeSwap. Validates our multi-band approach but argues for beforeSwap placement. |
| **Flaunch** (Flayer Labs) | MIT | Hook fee extraction + buyback | 100% fee capture, split between creator revenue + Progressive Bid Wall. Validates asymmetric fee routing. |
| **Clanker V4** | Unspecified | Per-swap fee collection | Multi-recipient fee distribution. Dynamic volatility-based fees. |
| **Unipump** | MIT | Asymmetric buy/sell fees | Only FOSS project with explicit directional fees (0.1% buy / 1% sell). Uses NoOp/custom accounting — different architecture. |
| **Brokkr PoC** | Unspecified | afterSwap rebalancing | Dual-range (wide + narrow) with afterSwap auto-rebalance. Gas paid by swapper. Validates our callback placement. |
| **OZ BaseCustomCurve** | MIT | Standard V4 curve building block | Alternative architecture: replace V4 math entirely instead of managing LP positions. Simpler but loses ecosystem visibility (no real tick liquidity for indexers). |

**Academic foundation:** Concentrated LP positions are mathematically equivalent
to bonding curve segments (arXiv 2407.02496). A collection of positions at
different tick ranges IS a discrete bonding curve. Trinity's approach is
theoretically sound.

**Design choice — LP bands vs custom accounting:** Doppler and Bunni validate
the LP-band approach. OZ BaseCustomCurve and Unipump show the alternative
(replace AMM math entirely). We keep LP bands because:
- Indexer visibility (GeckoTerminal, Dexscreener see real tick liquidity)
- Ecosystem compatibility (aggregators route through real AMM)
- MEV/arb activity (bots can find and trade the pools)
- The trade-off (gas cost from rebalancing) is acceptable on Base (~$0.01/swap)

---

## V5 Audit Findings → V6 Fixes

| ID | Finding | V6 Fix |
|---|---|---|
| C-01 | LP owned by LPSeeder, hook can't manage it | Hook seeds its own LP via `ownerSeedBand()` |
| H-01 | `withdrawLP` reverts (no unlock context) | Wrap in `manager.unlock()` callback |
| H-02 | exactOutput bypasses 1% fee | Revert on exactOutput (`amountSpecified >= 0`) |
| H-03 | `_computeLiquidity` uint256 overflow | Use divide-first pattern (deploy script's approach) |
| H-04 | Single-step band transition | Bounded `while` loop (max 5 steps) |
| C-02 | LP permanently locked | `withdrawLP` fix (H-01) + hook owns positions |
| C-03 | exactOutput + multi-call band manipulation | Blocked by H-02 fix (exactOutput reverts) |
| M-01 | `initialized` never set | Set `config.initialized = true` after registration |
| M-02 | Dead refund code, stranded PM credits | Settle exact amounts, not full balance |
| M-03 | `band.liquidity` overwrites | Accumulate: `band.liquidity += newLiquidity` |
| L-06 | External LP bypasses band tracking | Block external LP via `beforeAddLiquidity` |
| NEW  | No graduation path | `graduated` flag, lifts restrictions at terminal price |

---

## Architecture

```
          PERMANENT BONDING CURVE (no graduation)
   ┌──────────────────────────────────────────┐
   │        TrinityHookV6                      │
   │                                           │
   │  beforeAddLiquidity:                      │
   │    BLOCK external LP permanently          │
   │    only hook can add                      │
   │                                           │
   │  beforeSwap:                              │
   │    revert if exactOutput                  │
   │    1% fee extraction                      │
   │    buy → feeRecipient                     │
   │    sell → burn to 0xdead                  │
   │                                           │
   │  afterSwap:                               │
   │    while (tick outside band):             │
   │      remove LP from old band              │
   │      advance activeBand                   │
   │      add LP to new band                   │
   │      (max 5 iterations)                   │
   │                                           │
   │  At final band ceiling:                   │
   │    LP stays in last band, no transition   │
   │    fees continue collecting               │
   │                                           │
   │  ownerSeedBand (onlyOwner):               │
   │    PM.unlock() → modifyLiq                │
   │    hook owns the position                 │
   │                                           │
   │  emergencyWithdrawLP (owner):             │
   │    PM.unlock() → remove LP                │
   │    tokens → owner                         │
   └──────────────────────────────────────────┘
     ↕ PM callbacks    ↕ owner calls
   PoolManager          Multisig
```

### Permission Bits

```
BEFORE_ADD_LIQUIDITY        (bit 11) — block external LP (new in V6)
BEFORE_SWAP                 (bit 7)  — fee extraction
BEFORE_SWAP_RETURNS_DELTA   (bit 3)  — modify input for fee
AFTER_SWAP                  (bit 6)  — band rebalancing
```

No AFTER_INITIALIZE (LP seeded via owner function, not during init).

**Note:** Adding BEFORE_ADD_LIQUIDITY changes the required address bits.
New hook address must be mined with the updated flag mask.

---

## Contract: TrinityHookV6

### State

```solidity
struct Band {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;  // actual tracked liquidity in this band
}

struct PoolConfig {
    Band[] bands;
    uint256 activeBand;
    address feeRecipient;
    bool triIsCurrency0;
    bool initialized;       // set to true in registerPool
    bool seeded;            // set to true after ownerSeedBand
    // graduated field was removed — curves are permanent, no graduation
}

mapping(PoolId => PoolConfig) public pools;
```

### Owner Functions

#### `registerPool` (fix M-01)

Same as V5 but adds at the end:
```solidity
config.initialized = true;
```

Also add input validation:
```solidity
require(tickLowers.length == tickUppers.length, "length mismatch");
require(feeRecipient != address(0), "zero recipient");
for (uint256 i = 0; i < tickLowers.length; i++) {
    require(tickLowers[i] < tickUppers[i], "invalid band");
    require(tickLowers[i] % key.tickSpacing == 0, "tick alignment");
    require(tickUppers[i] % key.tickSpacing == 0, "tick alignment");
}
```

#### `ownerSeedBand` (fix C-01)

New function. The hook calls `PM.unlock()` itself, becoming the position owner.

```solidity
function ownerSeedBand(
    PoolKey calldata key,
    uint256 bandIndex,
    uint128 liquidity
) external onlyOwner {
    // Hook must hold sufficient tokens (transferred by owner beforehand)
    manager.unlock(abi.encode(
        CallbackType.SEED, abi.encode(key, bandIndex, liquidity)
    ));
    
    PoolId id = key.toId();
    pools[id].bands[bandIndex].liquidity += liquidity;
    if (!pools[id].seeded) pools[id].seeded = true;
}
```

The unlock callback does:
```solidity
// modifyLiquidity with positive delta (add LP)
// settle tokens from hook's balance to PM
// hook is msg.sender to PM → hook owns the position
```

#### `emergencyWithdrawLP` (fix H-01)

```solidity
function emergencyWithdrawLP(
    PoolKey calldata key,
    uint256 bandIndex
) external onlyOwner {
    manager.unlock(abi.encode(
        CallbackType.WITHDRAW, abi.encode(key, bandIndex)
    ));
}
```

The unlock callback does:
```solidity
// modifyLiquidity with negative delta (remove LP)
// take tokens from PM → transfer to owner
// band.liquidity = 0
```

#### `withdrawTokens` (unchanged)

Emergency ERC20 withdrawal from hook contract. Already works in V5.

### Unlock Callback Router

Single `unlockCallback` that dispatches based on a `CallbackType` enum:

```solidity
enum CallbackType { SEED, WITHDRAW }

function unlockCallback(bytes calldata data) external returns (bytes memory) {
    require(msg.sender == address(manager), "not PM");
    (CallbackType ctype, bytes memory payload) = abi.decode(data, (CallbackType, bytes));
    
    if (ctype == CallbackType.SEED) return _handleSeed(payload);
    if (ctype == CallbackType.WITHDRAW) return _handleWithdraw(payload);
    revert("unknown callback");
}
```

### `beforeAddLiquidity` — Block External LP (Bunni V2 pattern)

```solidity
function beforeAddLiquidity(
    address sender,
    PoolKey calldata,
    IPoolManager.ModifyLiquidityParams calldata,
    bytes calldata
) external override onlyPoolManager returns (bytes4) {
    // Only the hook itself can add LP — permanently.
    // The hook is msg.sender to PM during unlock callbacks,
    // and PM passes the original caller as `sender`.
    if (sender != address(this)) {
        revert OnlyHookCanAddLiquidity();
    }
    return IHooks.beforeAddLiquidity.selector;
}
```

Why: External LP would desync the hook's band tracking and dilute the
bonding curve mechanics. The restriction is permanent — there is no
graduation in V6. The multisig can use `emergencyWithdrawLP` if needed.

---

### No Graduation (Design Decision)

Early V6 designs included a graduation mechanism (bonding curve → standard
pool). This was removed after the audit found that auto-graduation was
exploitable via flash loans (P3-#6). An owner-only `graduatePool()` was
considered but ultimately cut — the curves are designed to be permanent
infrastructure, not a step toward graduation.

**When price exits the final band:** LP stays in the last band. The hook
continues to collect fees. No state transition occurs. The multisig can
use `emergencyWithdrawLP` to reposition LP if needed.

**Why no graduation:** The USDC curve is 327,612x deep — it never graduates
in practice. ChaosLP is 1,045x — theoretically reachable but its volatile
underlying means price oscillates rather than climbing. Keeping the fee
mechanism permanent maximizes the arb flywheel's lifetime.

---

### beforeSwap (fix H-02)

```solidity
function beforeSwap(...) external override onlyPoolManager
    returns (bytes4, BeforeSwapDelta, uint24)
{
    // REVERT on exactOutput — closes the fee bypass
    if (params.amountSpecified >= 0) {
        revert ExactOutputNotSupported();
    }
    
    // ... rest identical to V5 (fee extraction logic)
}
```

### afterSwap — Multi-Band Rebalancing (fix H-04)

```solidity
uint256 private constant MAX_BAND_STEPS = 5;

function _checkAndRebalance(
    PoolKey calldata key,
    PoolConfig storage config,
    PoolId id
) internal {
    (, int24 currentTick,,) = manager.getSlot0(id);
    
    uint256 steps;
    while (steps < MAX_BAND_STEPS) {
        uint256 active = config.activeBand;
        Band storage band = config.bands[active];
        
        if (currentTick >= band.tickUpper && active < config.bands.length - 1) {
            _removeLiquidityFromBand(key, config, active);
            config.activeBand = active + 1;
            _addLiquidityToBand(key, config, active + 1);
            emit BandTransition(id, active, active + 1);
            steps++;
        } else if (currentTick < band.tickLower && active > 0) {
            _removeLiquidityFromBand(key, config, active);
            config.activeBand = active - 1;
            _addLiquidityToBand(key, config, active - 1);
            emit BandTransition(id, active, active - 1);
            steps++;
        } else {
            break; // price is within current band
        }
    }
}
```

5 steps max caps gas at ~5x single-band cost. For Trinity's 12-15 bands per
pool, even extreme price moves are covered in 3 swaps maximum.

### `_computeLiquidity` (fix H-03)

Use divide-first pattern from the deploy script:

```solidity
function _computeLiquidity(
    uint160 sqrtCurrent,
    uint160 sqrtLower,
    uint160 sqrtUpper,
    uint256 amount0,
    uint256 amount1
) internal pure returns (uint128) {
    if (sqrtCurrent < sqrtLower) sqrtCurrent = sqrtLower;
    if (sqrtCurrent > sqrtUpper) sqrtCurrent = sqrtUpper;

    uint128 liq0 = type(uint128).max;
    if (sqrtCurrent < sqrtUpper) {
        uint256 diff = uint256(sqrtUpper) - uint256(sqrtCurrent);
        // Divide first to avoid overflow:
        // L = amount0 * sqrtCurrent * sqrtUpper / diff / 2^96
        // → (amount0 * sqrtCurrent / diff) * sqrtUpper >> 96
        uint256 intermediate = (amount0 * uint256(sqrtCurrent)) / diff;
        uint256 result = (intermediate * uint256(sqrtUpper)) >> 96;
        if (result <= type(uint128).max) {
            liq0 = uint128(result);
        }
        // else: liq0 stays at max, liq1 will be the binding constraint
    }

    uint128 liq1 = type(uint128).max;
    if (sqrtCurrent > sqrtLower) {
        uint256 diff = uint256(sqrtCurrent) - uint256(sqrtLower);
        uint256 result = (amount1 << 96) / diff;
        if (result <= type(uint128).max) {
            liq1 = uint128(result);
        }
    }

    return liq0 < liq1 ? liq0 : liq1;
}
```

### `_addLiquidityToBand` (fix M-02, M-03)

Key changes:
1. Compute exact amounts needed BEFORE settling (not full balance)
2. Accumulate `band.liquidity` instead of overwriting

```solidity
function _addLiquidityToBand(
    PoolKey calldata key,
    PoolConfig storage config,
    uint256 bandIndex
) internal {
    Band storage band = config.bands[bandIndex];
    
    uint256 balance0 = IERC20Minimal(Currency.unwrap(key.currency0))
        .balanceOf(address(this));
    uint256 balance1 = IERC20Minimal(Currency.unwrap(key.currency1))
        .balanceOf(address(this));
    
    if (balance0 == 0 && balance1 == 0) return;
    
    uint160 sqrtLower = TickMath.getSqrtPriceAtTick(band.tickLower);
    uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(band.tickUpper);
    (, int24 currentTick,,) = manager.getSlot0(key.toId());
    uint160 sqrtCurrent = TickMath.getSqrtPriceAtTick(currentTick);
    
    uint128 liquidity = _computeLiquidity(
        sqrtCurrent, sqrtLower, sqrtUpper, balance0, balance1
    );
    if (liquidity == 0) return;
    
    // Approve PM (needed for settle pattern)
    IERC20Minimal(Currency.unwrap(key.currency0)).approve(address(manager), balance0);
    IERC20Minimal(Currency.unwrap(key.currency1)).approve(address(manager), balance1);
    
    // Add LP — PM will pull exactly what it needs via the delta
    (BalanceDelta delta,) = manager.modifyLiquidity(
        key,
        IPoolManager.ModifyLiquidityParams({
            tickLower: band.tickLower,
            tickUpper: band.tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(bandIndex)
        }),
        ""
    );
    
    // Settle the negative deltas (what PM consumed)
    if (delta.amount0() < 0) {
        _settleTokens(key.currency0, uint256(uint128(-delta.amount0())));
    }
    if (delta.amount1() < 0) {
        _settleTokens(key.currency1, uint256(uint128(-delta.amount1())));
    }
    
    // Accumulate, don't overwrite
    band.liquidity += liquidity;
}
```

---

## Deployment Flow

```
1. Deploy TrinityHookV6 via CREATE2 (same permission bits)
2. Deploy TrinityToken (or reuse V5 token if supply allows)
3. registerPool() for each of the 3 pools (USDC, WETH, ChaosLP)
4. PM.initialize() for each pool
5. Transfer TRINI to hook contract
6. ownerSeedBand(poolKey, 0, liquidity) for each pool
   → hook calls PM.unlock() → modifyLiquidity → hook owns the position
   → band[0].liquidity is correctly tracked
7. Transfer hook ownership to multisig
```

Step 6 is the critical difference from V5. The hook creates and owns its LP
positions directly. No external LPSeeder needed.

---

## Migration from V5

V5's LP is permanently locked (C-02). Options:

**Option A: Fresh token + fresh pools.** Deploy new TRINI V2 token. Airdrop to
existing TRINI holders (snapshot). Clean start with correct LP ownership.

**Option B: Same token, new pools.** Keep the existing TRINI token. Deploy new
hook + register new pools. Old V5 pools remain live but unmaintained (LP is
stuck, fee collection still works within band 0). New V6 pools get fresh LP
from treasury allocation.

**Option C: Burn-and-migrate.** V5 pools stay live. New V6 pools use same TRINI
token. Users can trade on either. Over time, V5 pools have zero volume (no
marketing/frontend support) and V6 pools take over. The $93K TVL in V5 is
effectively a donation to the PM.

**Recommended: Option B.** Least disruptive. Same token, same staking. Frontend
points to new V6 pool addresses. Old pools are abandoned but not harmful.

---

## New Test Cases Required

In addition to V5's existing 12 tests:

| Test | What It Validates |
|---|---|
| `test_exactOutputReverts` | H-02: exactOutput swap is blocked |
| `test_ownerSeedBand_tracksLiquidity` | C-01: band.liquidity matches actual PM position |
| `test_multiBandJump` | H-04: large swap triggers multiple band transitions |
| `test_multiBandJump_cappedAt5` | H-04: while loop stops at MAX_BAND_STEPS |
| `test_emergencyWithdrawLP` | H-01: owner can recover LP from PM |
| `test_registerPool_doubleCall_reverts` | M-01: second registerPool fails |
| `test_computeLiquidity_largeAmounts` | H-03: no overflow with 300M TRINI |
| `test_addLiquidity_noStrandedTokens` | M-02: PM deltas balance after add |
| `test_bandLiquidity_accumulates` | M-03: oscillating transitions track correctly |
| `test_fullCurveTraversal` | E2E: buy through all 15 bands, sell back down |
| `test_flashLoanBandManipulation` | C-06: flash loan can't profit from band desync |
| `test_externalLP_blocked` | beforeAddLiquidity reverts for non-hook callers |
| `test_externalLP_alwaysBlocked` | External LP blocked even after many swaps |
| `test_updateFeeRecipient` | Fee recipient can be changed by owner |
| `test_bandContiguity_required` | Non-contiguous bands rejected |
| `test_pmBalanceInvariant` | PM token balance never decreases after swap |

---

## Gas Estimates (Base)

| Operation | Gas (est.) | Cost @ 0.01 gwei |
|---|---|---|
| Swap (no band transition) | ~180K | ~$0.004 |
| Swap (1 band transition) | ~350K | ~$0.008 |
| Swap (5 band transitions, max) | ~1.1M | ~$0.025 |
| ownerSeedBand | ~250K | ~$0.006 |
| emergencyWithdrawLP | ~200K | ~$0.005 |

All within Base's practical limits. The 5-transition max is the gas ceiling
for any single swap.

---

## Curve Shape & Initial Market Cap

### Design Goal: Perpetual Arb Engine

Graduation is a safety valve, not a target. The real goal is **maximum
sustained arb volume** driving fees to stakers and the community treasury.
The curves should be long, never quite finishing, with persistent price
gaps between pools.

```
Early buyers get discount TRINI
  → price differs across 3 pools (different curve shapes)
    → arb bots buy cheap pool / sell expensive pool
      → every arb leg pays 1% fee (2% per cycle)
        → fees go to multisig → stakers get rewarded
          → stakers buy more TRINI → price rises → more arb → more fees
```

For this flywheel to spin, we need:
1. A genuine discount zone (~first 20%) that attracts early capital
2. Different curve shapes per pool so arb surfaces exist from day one
3. Very long curves that keep the bonding phase (and fees) running
   indefinitely under normal conditions

### Starting FDV: $25K

```
Base price:    $0.000025 / TRINI
Supply:        1B TRINI
Starting FDV:  $25,000
```

Why $25K:
- Low enough to feel like genuine ground floor
- High enough to not look like a rug
- The discount zone costs ~$50-$200 per pool to fill — a single
  early believer can kickstart the flywheel
- Massive room to run: 800x-1,500x+ to theoretical graduation

### Two Levers: Band Width + Token Allocation

We control curve shape with two independent levers:

**1. Band widths** — how much price moves per band:

```
Price movement per band = 1.0001^(bandWidth)

Steepness   Band width    Price per band   Character
──────────  ──────────    ──────────────   ─────────
8/10        1,200 ticks   1.13x            Ignition — $10 moves the needle
6/10        2,000 ticks   1.22x            Decelerating
4/10        3,400 ticks   1.41x            Settling
2/10        6,800 ticks   1.97x            Cruising — deep, stable
1/10        10,000 ticks  2.72x            Anchored — barely moves
```

**2. Token allocation** — how much depth each pool has:

```
Pool        TRINI allocated % of LP supply   Depth character
──────────  ─────────────   ──────────────   ──────────────
USDC        450M            50%              Very deep — the bedrock
WETH        297M            33%              Moderate
ChaosLP     153M            17%              Thin — every trade moves price
Treasury    100M            —                Reserved
Total       1B
```

These are multiplicative. ChaosLP has steep bands AND thin depth.
USDC has flat bands AND deep depth. The price impact ratio between
them is ~12-15x — a $20 ChaosLP buy does what a $250 USDC buy does.

This matches reality: ChaosLP is a $2,600 MC token. Nobody's putting
$10K of it into anything. It doesn't need depth — it needs sensitivity.
153M TRINI is still far more than will ever trade in a single session,
but thin enough that every trade creates a visible move.

The nonlinearity comes from the band width schedule + allocation.
The hook doesn't know or care — it just moves LP between bands.

### Proposed Band Schedules

Three pools, three different shapes. All start at the same base price
($0.000025) but accelerate differently. Wide curves = long bonding
phase = sustained fee generation.

#### All Pools — Shared Ignition (Band 0)

Every pool starts with the same steep band: 1,200 ticks (1.13x).
This is price discovery. Even a $10 buy moves the price visibly.
All three pools diverge from the very first trade.

After ignition, each pool decelerates at a different rate.

#### USDC Pool — Fast Deceleration (450M TRINI, 16 bands)

The anchor. Decelerates quickly into deep, flat bands. Where most
organic buying lands. Barely moves after ignition settles.

```
Band  Width   Steep  Cumul ×   Character
───── ─────── ─────  ────────  ─────────
 0    1,200   8/10   1.13x     ignition (shared)
 1    2,000   6/10   1.38x     ┐ deceleration
 2    3,400   4/10   1.94x     ┘
 3    6,800   2/10   3.83x     ┐
 4    6,800   2/10   7.55x     │
 5    6,800   2/10   14.91x    │ deep cruising
 6   10,000   1/10   40.52x    │
 7   10,000   1/10   110.13x   │
 8   10,000   1/10   299.29x   │
 9   10,000   1/10   813.21x   ┘
10   10,000   1/10   2,210.0x  ┐
11   10,000   1/10   6,005.7x  │ anchored long tail
12   10,000   1/10   16,322x   │
13   10,000   1/10   44,355x   │
14   10,000   1/10   120,560x  │
15   10,000   1/10   327,612x  ┘

Base: $0.000025 → Terminal: $8.19 → FDV at graduation: ~$8.2B
Total curve: 327,612x — effectively infinite. Never graduates.
Depth: 450M TRINI. $100 moves price ~0.8% after settling.
```

#### WETH Pool — Medium Deceleration (297M TRINI, 15 bands)

The relay. Moderate deceleration, moderate depth. ETH's own price
movements add a second dimension of dislocation.

```
Band  Width   Steep  Cumul ×   Character
───── ─────── ─────  ────────  ─────────
 0    1,200   8/10   1.13x     ignition (shared)
 1    2,000   6/10   1.38x     ┐ deceleration
 2    3,400   5/10   1.94x     ┘
 3    3,400   4/10   2.73x     ┐
 4    3,400   4/10   3.84x     │ settling
 5    3,400   4/10   5.41x     ┘
 6    6,800   2/10   10.67x    ┐
 7    6,800   2/10   21.06x    │ moderate cruising
 8    6,800   2/10   41.56x    │
 9    6,800   2/10   82.01x    ┘
10   10,000   1/10   222.89x   ┐
11   10,000   1/10   605.65x   │ long tail
12   10,000   1/10   1,645.9x  │
13   10,000   1/10   4,473.3x  │
14   10,000   1/10   12,154x   ┘

Base: $0.000025 → Terminal: $0.304 → FDV at graduation: ~$304M
Total curve: 12,154x — reachable in theory, never in practice.
Depth: 297M TRINI. $100 moves price ~2% after settling.
```

#### ChaosLP Pool — Slow Deceleration (153M TRINI, 15 bands)

The volatility engine. Decelerates slowly — stays steep. ChaosLP
is a ~$2,600 MC token. Every buy moves TRINI's price significantly,
creating constant dislocations from the USDC baseline.

```
Band  Width   Steep  Cumul ×   Character
───── ─────── ─────  ────────  ─────────
 0    1,200   8/10   1.13x     ignition (shared)
 1    2,000   6/10   1.38x     ┐ slow deceleration
 2    2,000   5/10   1.68x     ┘
 3    3,400   4/10   2.37x     ┐
 4    3,400   4/10   3.33x     │ still steep
 5    3,400   4/10   4.69x     │
 6    3,400   4/10   6.60x     ┘
 7    3,400   3/10   9.29x     ┐
 8    3,400   3/10   13.07x    │ moderate
 9    3,400   3/10   18.40x    ┘
10    6,800   2/10   36.31x    ┐
11    6,800   2/10   71.67x    │ late cruising
12    6,800   2/10   141.45x   ┘
13   10,000   1/10   384.39x   ┐ tail
14   10,000   1/10   1,044.7x  ┘

Base: $0.000025 → Terminal: $0.0261 → FDV at graduation: ~$26.1M
Total curve: 1,045x — reachable but ChaosLP volatility means the
price oscillates rather than climbing steadily.
Depth: 153M TRINI. $20 moves price ~8% after settling.
```

**The combined effect:**

All three ignite together. Then USDC flattens out fast (the anchor),
ChaosLP stays volatile (the engine), and WETH sits in between (the
relay). ChaosLP's thin depth (153M) + slow deceleration means it
reacts 12-15x more per dollar than USDC's deep (450M) + fast
deceleration.

**The arb is bidirectional.** ChaosLP oscillates around the USDC
baseline. Every swing — up or down — generates fees. ChaosLP's
volatile underlying asset ensures constant price shocks that the
arb engine converts into fee revenue.

### The Arb Surface

The arb is **bidirectional** because ChaosLP's steep curve + volatile
underlying asset creates oscillating dislocations:

```
Scenario A — someone buys TRINI with ChaosLP:

              USDC pool    WETH pool    ChaosLP pool
Price         $0.00004     $0.00005     $0.00012
                                        ^^^ spiked

Arb: buy USDC (cheap, stable) → sell ChaosLP (spiked) → fees
```

```
Scenario B — ChaosLP underlying dumps 30%:

              USDC pool    WETH pool    ChaosLP pool
Price         $0.00004     $0.00005     $0.00003
                                        ^^^ depressed

Arb: buy ChaosLP (cheap) → sell WETH or USDC → fees
```

```
Scenario C — organic USDC buy from Farcaster user:

              USDC pool    WETH pool    ChaosLP pool
Price         $0.00004     $0.00003     $0.000035

USDC barely moves (flat curve absorbs it). Spread stays tight.
No arb needed — the flat curve is doing its job (good UX for buyer).
```

Every swing in ChaosLP — up or down — generates arb fees. USDC's flat
curve provides the stable reference. WETH sits in between, creating a
second relay for three-way arb paths.

The spread never fully closes because:
- ChaosLP's steep curve means any activity creates large price moves
- ChaosLP's volatile underlying means external price shocks constantly
  create new dislocations
- Every arb cycle costs 2% in fees, so bots stop at ~2% — then the
  next ChaosLP price move reopens the gap

### Market Cap Summary

```
                    TRINI     Base     Terminal    Total
Pool    Bands       alloc     FDV      FDV         curve
─────── ─────       ─────     ──────   ──────────  ──────────
USDC    16          450M      $25K     ~$8.2B      327,612x
WETH    15          297M      $25K     ~$304M      12,154x
ChaosLP 15          153M      $25K     ~$26.1M     1,045x
```

**USDC never graduates.** 327,612x with 450M depth — it would take
billions in organic buying. This pool generates fees forever.

**WETH is practically permanent too.** 12,154x. Theoretical but
unreachable under normal conditions.

**ChaosLP could theoretically graduate at ~$26M FDV.** But its
volatile underlying means the price oscillates rather than climbing
steadily. In practice, it stays in bonding curve mode, generating
fees on every swing.

**USDC is the anchor.** Deep (450M) + flat = stable pricing for
organic buyers + reliable baseline for arb bots.

**ChaosLP is the volatility engine.** Thin (153M) + steep = every
trade moves the price. Its micro-cap underlying ($2,600 MC) means
constant external price shocks that the arb engine converts into
fee revenue for stakers.

### Why Variable Band Widths, Not Bonding Curve Math

The V1 hook (`TrinityHook.sol`) used explicit bonding curve formulas
(`_calcTokensOut` with quadratic math). This worked but:
- Required custom quoter handling (try-catch hack)
- Made the pool invisible to indexers
- Needed WAD-scaled math with precision edge cases

Variable band widths give us the same nonlinear curve shape with zero
custom math in the contract. The hook is pure LP management — it
doesn't know or care that the bands form a curve.

Clanker's insight: the pool's LP distribution IS the curve. They use
two positions (concentrated + wide). We use 12-18 bands with varying
widths. Same concept, finer control.

### Implementation

No contract changes needed beyond what V6 already defines. The band
width schedule is passed to `registerPool` as tick arrays:

```solidity
// USDC pool — steep curve (15 bands)
int24[] usdcLowers = [tickBase, tickBase+6800, tickBase+13600, ...];
int24[] usdcUppers = [tickBase+6800, tickBase+13600, tickBase+17000, ...];

// ChaosLP pool — shallow curve (18 bands)
int24[] clpLowers  = [tickBase, tickBase+10000, tickBase+20000, ...];
int24[] clpUppers  = [tickBase+10000, tickBase+20000, tickBase+30000, ...];
```

The deploy script computes these from the band width schedules above.
`ownerSeedBand` seeds band 0 with the pool's TRINI allocation. The hook
handles the rest via rebalancing.

---

## Resolved Design Decisions

1. **LP bands, not BaseCustomCurve.** We keep LP bands because ecosystem
   visibility (GeckoTerminal, Dexscreener, aggregators) is the whole point
   of moving from V1's custom curve to V4. OZ BaseCustomCurve is simpler
   but invisible to indexers.

2. **afterSwap rebalancing, no keeper.** Simplest approach, no external
   dependencies, gas is cheap on Base ($0.025 worst case).

3. **1% fee, hardcoded.** All three pools use the same rate. Not worth
   the complexity of per-pool config for a prototype.

4. **Block external LP permanently.** Inspired by Bunni V2. No graduation
   means the hook always controls LP. Multisig has `emergencyWithdrawLP`.

5. **Add `ReentrancyGuard`.** Cheap insurance. Bunni V2's exploit was
   logic, not reentrancy, but defense in depth costs ~2400 gas per call.

## Resolved Questions

1. **TRINI token: fresh deploy.** V5's 900M is locked in old pools. V6
   deploys a fresh TrinityTokenV6 ("Trinity", "TRINI") with 1B supply.
   900M seeded across 3 pools, 100M to treasury multisig.

2. **No graduation.** Removed after audit (flash-loan exploit risk).
   Curves are permanent — fees collect forever. The USDC curve is
   327,612x deep, never graduating in practice. This is the design.
