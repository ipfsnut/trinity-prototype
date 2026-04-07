# Trinity Contract Audit — 2026-04-07

Three-pass security review of all deployed and in-repo contracts.

**Scope:**
- `TrinityHookV5.sol` (deployed, identical to V4) — the core hook
- `TrinityToken.sol` (deployed) — the ERC20
- `TrinityRouter.sol` (in repo, not used by frontend — Universal Router used instead)
- `DeployTrinityV5.s.sol` + `LPSeeder` (deployed) — deployment and LP seeding
- `HookMiner.sol`, `TokenMiner.sol` — CREATE2 utilities
- `TrinityHookV5.t.sol` — test coverage review

**Deployed addresses (Base):**
- TRIN: `0x1313b1B3387Ee849d549d9c9280148B237a375ae`
- TrinityHookV5: `0x1427050C1b5886471CA7ce656aB6ec22E86e40c8`
- Staking Hub: `0x61219b5F2a59A6F331Ce5362b30c8277Cb748cf8`

---

## PASS 1 — Line-by-line systematic review

### TrinityToken.sol

Clean. Standard OZ ERC20, 1B supply minted to deployer. No admin functions, no
mint/burn, no hooks. Nothing to flag.

---

### TrinityHookV5.sol

#### H-01: `withdrawLP` is non-functional (always reverts)

**Location:** Lines 144-166
**Severity:** HIGH

`withdrawLP` calls `manager.modifyLiquidity()` and `manager.take()` directly.
These require the caller to be within a PM `unlock()` context. This function is
called externally by the owner — it is NOT inside an unlock callback. Every call
will revert with the PM's "ManagerLocked" error.

**Impact:** The emergency LP withdrawal mechanism does not work. If something goes
wrong with the LP positions, there is no way to recover them. Combined with the
LP seeding issue (see C-01), initial LP is permanently locked.

#### H-02: exactOutput swaps bypass the 1% fee entirely

**Location:** Lines 197-200
**Severity:** HIGH

```solidity
if (params.amountSpecified >= 0) {
    return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
}
```

When `amountSpecified >= 0` (exactOutput), the hook returns zero delta — no fee
is extracted. The AMM runs the swap normally. Anyone can use Universal Router's
`SWAP_EXACT_OUT_SINGLE` command to trade fee-free on all three pools.

**Exploitation:** Trivial. Change the swap command from `0x06`
(SWAP_EXACT_IN_SINGLE) to `0x07` (SWAP_EXACT_OUT_SINGLE) in the Universal
Router call. No special contracts needed.

#### H-03: `_computeLiquidity` has uint256 overflow

**Location:** Lines 387-390
**Severity:** HIGH

```solidity
uint256 num = amount0 * uint256(sqrtCurrent);   // up to 2^250
liq0 = uint128(num * uint256(sqrtUpper) / denom / (1 << 96));
//              ^^^^^^^^^^^^^^^^^^^^^^^^^^^
//              2^250 * 2^160 = 2^410 — OVERFLOWS uint256
```

`amount0` (up to ~2^90 for 1B tokens at 18 decimals) times `sqrtCurrent`
(uint160) fits in uint256. But then `num * sqrtUpper` exceeds 2^256 and silently
wraps. The resulting liquidity value is wrong (much smaller than intended).

**Contrast:** The deploy script's `_computeLiquidityFromAmount0` (line 250) does
`(num / diff) * sqrtUpper >> 96` — divides first to avoid overflow. The hook's
version multiplies first.

**Impact:** When the hook tries to rebalance LP into a new band, it computes
incorrect liquidity. Less LP is deposited than the available tokens allow.

#### H-04: Band rebalancing only moves one step per swap

**Location:** Lines 266-281
**Severity:** HIGH

```solidity
if (currentTick >= currentBand.tickUpper && active < config.bands.length - 1) {
    // only transitions ONE band
}
```

If a large swap moves the price across multiple bands in one transaction, the
hook only transitions one band. The next swap transitions the next band, etc.
During this catch-up period:
- Liquidity is deployed in the wrong band (not where the price actually is)
- Users experience high slippage or failed swaps
- Takes N additional swaps to resynchronize

An attacker using exactOutput (no fee) can also weaponize this to desync the
hook's activeBand from the actual price.

#### M-01: `registerPool` never sets `initialized = true`

**Location:** Lines 113-136
**Severity:** MEDIUM

The guard at line 121 checks `config.initialized`, but the function never sets
it to `true`. A second call to `registerPool` for the same pool would:
1. Pass the guard
2. Overwrite `feeRecipient`, `triIsCurrency0`, `activeBand`
3. **Append** duplicate bands to the existing array (push, not reset)

This corrupts the band configuration. Owner-only, but a dangerous footgun.

#### M-02: Stranded tokens in `_addLiquidityToBand`

**Location:** Lines 314-338
**Severity:** MEDIUM

The function settles the hook's ENTIRE token balance to PM (lines 315-316),
then calls `modifyLiquidity` which consumes only what the computed liquidity
requires. Lines 333-338 attempt to reclaim the excess:

```solidity
if (delta.amount0() > 0) {
    manager.take(key.currency0, address(this), ...);
}
```

But for `modifyLiquidity` with positive liquidityDelta (adding LP), the delta
amounts are **negative** (PM consumed tokens). `delta.amount0() > 0` is never
true. This code is **dead** — excess tokens are stranded as unrecoverable PM
credits.

#### M-03: `band.liquidity` overwrites instead of accumulating

**Location:** Line 330
**Severity:** MEDIUM

```solidity
band.liquidity = liquidity;  // overwrites, doesn't add
```

If a band is rebalanced into multiple times (e.g., price oscillates across a
boundary), the tracked liquidity only reflects the last addition, not the
cumulative total. When `_removeLiquidityFromBand` later tries to remove
`band.liquidity`, it removes less than what's actually there, leaving orphaned
liquidity in PM.

#### M-04: TrinityRouter doesn't refund excess pre-settle on partial fills

**Location:** `TrinityRouter.sol` unlockCallback, lines 161-201
**Severity:** MEDIUM (only relevant if TrinityRouter is used)

The router pre-settles the full input amount, but doesn't refund the difference
if the AMM consumes less. The test's `SwapRouter` contract does handle this
(lines 150-168) but the production router doesn't.

Note: The frontend uses Universal Router, not TrinityRouter, so this only
affects any direct TrinityRouter callers (arb bot, scripts).

#### M-05: `sellTriForETH` has reentrancy surface

**Location:** `TrinityRouter.sol` line 157
**Severity:** MEDIUM (only relevant if TrinityRouter is used)

```solidity
(bool sent,) = msg.sender.call{value: ethOut}("");
```

ETH transfer to an arbitrary `msg.sender` after state changes. If `msg.sender`
is a contract with a malicious `receive()`, it could re-enter. All critical
state is already updated, so direct exploit is unlikely, but no `ReentrancyGuard`
is present.

#### L-01: Duplicate import

**Location:** Lines 10-11
**Severity:** LOW

```solidity
import {BeforeSwapDelta, toBeforeSwapDelta} from "...";
import {BeforeSwapDelta} from "...";  // duplicate
```

Harmless but indicates code was hastily assembled.

#### L-02: Unused import

**Location:** Line 9
**Severity:** LOW

`toBalanceDelta` is imported but never used.

#### L-03: No input validation in `registerPool`

**Location:** Lines 113-136
**Severity:** LOW (owner-only)

Missing validations:
- `tickLowers.length == tickUppers.length`
- `tickLower < tickUpper` per band
- Bands are contiguous (tickUpper[i] == tickLower[i+1])
- `feeRecipient != address(0)`
- Tick values are multiples of `key.tickSpacing` (200)

All would cause reverts downstream if violated, but better to fail early with
clear errors.

#### L-04: No reentrancy guard on hook

**Location:** Entire contract
**Severity:** LOW

The hook makes external ERC20 calls (transfer, approve) during PM callbacks.
PM's transient lock prevents re-entering `swap()`, and the hook's external
functions are `onlyPoolManager` or `onlyOwner`, limiting re-entry vectors. But
if any token has transfer hooks (ERC-777 etc.), there's a theoretical path.

All three current tokens (TRIN, USDC, WETH) are safe. ChaosLP has custom
Permit2 behavior but no transfer hooks.

#### L-05: `int128(uint128(fee))` cast in `beforeSwap`

**Location:** Line 231
**Severity:** LOW

If `fee > type(int128).max` (~1.7e38), the cast silently wraps to negative.
Requires an impossibly large swap amount (more than the total supply of any
real token).

#### L-06: External LP bypasses hook band tracking

**Location:** Lines 437-456
**Severity:** LOW

`beforeAddLiquidity` and `beforeRemoveLiquidity` return success for any caller.
External LP additions/removals are not reflected in the hook's `band.liquidity`
tracking, potentially desynchronizing the hook's view of pool state.

#### L-07: Burn via `0xdead` doesn't reduce `totalSupply()`

**Location:** Line 43
**Severity:** LOW / INFO

Tokens "burned" to `0xdead` remain in `totalSupply()`. Analytics, market cap
calculations, and FDV all overcount. Using a proper `burn()` function (if
available on TRI) would reduce supply. TRI inherits OZ ERC20 which has
`_burn()` but it's internal — the hook can't call it. Would need a public
`burn()` on TRI, which doesn't exist.

---

### TrinityRouter.sol

#### L-08: `triOut` / `quoteOut` cast can produce wrong value

**Location:** Lines 90, 120, 153
**Severity:** LOW

```solidity
triOut = uint256(uint128(d0 > 0 ? d0 : d1));
```

If both deltas are negative (abnormal swap result), the code takes `d1` and
casts a negative int128 to uint128, producing a huge incorrect value. Normal
swaps always produce one positive delta, so this is theoretical.

---

### DeployTrinityV5.s.sol

#### L-09: `_computeLiquidityFromAmount0` precision loss

**Location:** Lines 249-250
**Severity:** LOW

```solidity
uint256 L = (num / diff) * uint256(sqrtUpper) >> 96;
```

Dividing before multiplying avoids overflow (correctly!) but loses precision
from the truncating integer division. For the actual deployment parameters this
precision loss is negligible.

---

### Test Coverage Gaps

The test file `TrinityHookV5.t.sol` covers basic flows but is missing:

| Missing Test | Why It Matters |
|---|---|
| exactOutput swap (fee bypass) | H-02: anyone can trade fee-free |
| Multi-band price jump | H-04: rebalancing gets stuck one band behind |
| `withdrawLP` call | H-01: would immediately reveal it reverts |
| Double `registerPool` call | M-01: would show bands get duplicated |
| `_computeLiquidity` with real balances | H-03: would reveal overflow |
| External LP addition + band transition | L-06: would show tracking desync |
| Sell exceeding totalSold (V1 hook) | Edge case in old hook's sell guard |

---

## PASS 2 — Cross-cutting concerns & interaction patterns

### C-01: Initial LP is not tracked by hook — rebalancing is broken

**Severity:** CRITICAL

This is the most impactful finding. The deploy script seeds LP into band 0 via
`LPSeeder`, which calls `PM.modifyLiquidity()` directly. The hook's internal
`band[0].liquidity` remains **0** (set during `registerPool`, never updated).

When the first band transition fires in `_checkAndRebalance`:
1. `_removeLiquidityFromBand(key, config, 0)` is called
2. `band.liquidity == 0` → **returns immediately** (line 347)
3. The externally seeded LP in band 0 is NOT removed from PM
4. `_addLiquidityToBand(key, config, 1)` is called
5. Hook's token balances are 0 (nothing was withdrawn) → **returns immediately**
6. Band 1 gets zero liquidity

**Result:** Band transitions are no-ops. The LP stays permanently in band 0.
The hook's `activeBand` counter advances but no actual liquidity moves. Once the
price exits band 0's range, there is no LP anywhere — swaps fail or have extreme
slippage.

**Note:** The LPSeeder uses `salt: bytes32(0)` which matches the hook's
`salt: bytes32(bandIndex)` for band 0. So the hook COULD manage this position if
it knew the liquidity amount. The fix requires either:
- An owner function to sync `band.liquidity` with the actual PM position, or
- Seeding LP through the hook itself (add an owner `seedBand` function), or
- Reading the actual position from PM in `_removeLiquidityFromBand` instead of
  trusting the internal tracker

### C-02: Permanent LP lock

**Severity:** HIGH

Since `withdrawLP` doesn't work (H-01) and the LPSeeder contract has no remove
function (only `seed` and `rescue`), the initial LP is **permanently locked** in
the PoolManager. It cannot be recovered, even by the multisig.

If Trinity needs to migrate to a new hook version or wind down, there is no way
to recover the LP tokens from PM.

### C-03: exactOutput + multi-call = fee-free band manipulation

**Severity:** HIGH

An attacker can combine H-02 (exactOutput fee bypass) with repeated swaps to
manipulate the hook's band state without paying any fees:

1. exactOutput buy → push price into band 1 (hook transitions 0→1, no fee)
2. exactOutput sell → push price back to band 0 (hook transitions 1→0, no fee)
3. Repeat to desynchronize hook state

Since band rebalancing is already broken (C-01), this is secondary. But in a
fixed version, this would be the primary attack vector.

### C-04: No hook permission for afterInitialize — LP seeding design

**Severity:** INFO (design note)

The hook's address doesn't have AFTER_INITIALIZE permission bits, so PM doesn't
call `afterInitialize` during pool creation. This is why LP must be seeded
separately via the deploy script. The NatSpec on line 32 documents this:
"afterInitialize is NOT used — modifyLiquidity requires unlock context."

This is correct — but it creates the C-01 tracking gap as a side effect.

### C-05: Fee recipient DoS vector

**Severity:** LOW

If `feeRecipient` is changed (possible via M-01's registerPool double-call) to
a contract that reverts on ERC20 receive, all buy swaps would revert at line 220.
Sell swaps (which burn to 0xdead) would be unaffected.

Current feeRecipient is a Safe multisig — safe. But worth noting for governance.

### C-06: Flash loan price manipulation

**Severity:** LOW-MEDIUM (theoretical with current broken rebalancing)

An attacker could flash borrow tokens, push the price across band boundaries in
one transaction, trigger band transitions, then repay the flash loan. With the
single-step limitation (H-04), only one band transitions per swap, limiting the
damage. But combined with exactOutput (H-02), the attacker pays no fees, making
the attack cheaper.

With the current broken rebalancing (C-01), this is moot — there's nothing to
manipulate. But in a fixed version, this should be defended against.

---

## PASS 3 — Self-critique and adversarial re-examination

Passes 1 and 2 focused on obvious bugs and known patterns. This pass asks:
"What did I assume was safe that might not be?"

### R-01: Is the PM's transient lock actually sufficient?

**Re-examined:** The PM's transient lock prevents re-entering `unlock()`. But
the hook calls `modifyLiquidity()` inside `afterSwap`, which is already within
an `unlock()` context. The PM allows nested `modifyLiquidity` calls within an
active unlock. This is correct — V4 is designed for hooks to modify positions
during callbacks.

But what about the **delta accounting**? During `afterSwap`, the hook:
1. Removes LP (modifyLiquidity with negative delta → PM owes tokens to hook)
2. Takes tokens from PM (via `_takeTokens`)
3. Adds LP to new band (settles tokens to PM → hook owes tokens to PM)
4. Calls modifyLiquidity with positive delta

All of these create credits/debits in the PM's transient accounting. At the end
of the outer `unlock()`, PM verifies all deltas are settled. If the hook's
internal operations don't net to zero, the entire transaction reverts.

**Potential issue:** In `_addLiquidityToBand`, the hook settles its ENTIRE balance
(lines 315-316) but `modifyLiquidity` may consume less. The excess is settled but
not consumed, creating an unmatched credit. This credit would need to be taken
back for the unlock to complete. But the "take back unused" code is dead (M-02).

**Wait — this means the unlock should revert!** If excess tokens are settled but
not taken back, the PM's delta accounting would show an imbalance. The outer
swap's unlock would fail.

Re-examining: The hook settles tokens via `_settleTokens` which calls
`sync → transfer → settle`. This creates a net-zero credit (PM receives tokens
and records the settlement). Then `modifyLiquidity` records that the LP consumes
some amount. The delta from modifyLiquidity should reflect what PM consumed from
the settlement. If PM consumed less than was settled, there's excess credit.
The PM checks that all currency deltas are zero at unlock close. If there's
unclaimed credit, the unlock reverts.

**This means:** Either (a) the excess settle/take accounting actually works
correctly and I misread the delta signs, or (b) band transitions would cause the
entire swap to revert. Since the pools are live and trades are going through,
and band transitions may not have fired yet (C-01 makes them no-ops), this
hasn't been tested in production.

**Verdict:** This needs a dedicated test with an actual band transition that has
excess tokens. The current test suite doesn't trigger this path with meaningful
liquidity differences.

### R-02: Is the `salt` parameter correctly isolating positions?

**Re-examined:** The hook uses `salt: bytes32(bandIndex)` for its positions.
Different bands get different salts. This means the PM tracks them as separate
positions. When removing band 0's LP, only the position with salt=0 is affected.

The LPSeeder also uses `salt: bytes32(0)`. So both the seeder and hook reference
the same position for band 0. But the position is owned by the **seeder
contract** (the LP position's owner is the address that called `modifyLiquidity`).
When the hook tries to remove this position, it's calling `modifyLiquidity` from
a DIFFERENT address. PM should reject this — you can't modify someone else's
position!

**This is an additional problem with C-01:** Even if `band.liquidity` were
correct, the hook can't remove the seeder's position because the hook isn't the
position owner. The seeder created the position, so only the seeder (or someone
with the seeder's address) can remove it.

Wait — in V4, `modifyLiquidity` positions are keyed by `(owner, tickLower,
tickUpper, salt)`. The "owner" is `msg.sender` to the PM (which, inside an
unlock callback, is the callback caller — in this case, the hook). So the
hook's positions are keyed to the hook's address, and the seeder's positions
are keyed to the seeder's address.

**Confirmed:** The hook CANNOT remove the seeder's LP position. They are
different owners. The LP seeded by the deploy script is not manageable by the
hook at all. The hook can only manage positions it created itself.

**Impact:** Even fixing the band.liquidity tracking (C-01) would not fix
rebalancing. The initial LP needs to be seeded BY the hook or the hook needs
to be the position owner. This upgrades C-01 from CRITICAL to **CRITICAL WITH
NO SIMPLE FIX** in the current deployed contract.

### R-03: Can the multisig rescue anything?

**Re-examined:** The multisig owns the hook. Available functions:
- `registerPool` — can re-register (due to M-01 bug), corrupts bands
- `withdrawTokens` — can withdraw ERC20 tokens held by the hook contract. This
  works for any tokens that end up in the hook (e.g., from fee take operations
  or rebalancing). But the initial LP tokens are in PM, not in the hook.
- `withdrawLP` — broken (H-01), always reverts
- `transferOwnership` — can transfer hook ownership

The seeder contract has:
- `rescue(token, to)` — can recover ERC20 tokens held by the seeder (already
  called in deploy script). But can't interact with PM positions.
- `seed(...)` — can add more LP. But the LP would be owned by the seeder, not
  the hook.

**Conclusion:** The multisig can withdraw tokens held by the hook contract, but
cannot touch the LP positions in PM. The LP is permanently locked with no
recovery path.

### R-04: What's the actual user impact right now?

Given C-01 and R-02, the band rebalancing **does not function**. But the pools
are live and trades are happening. Why?

Because the initial LP in band 0 provides liquidity for swaps within band 0's
price range. The AMM works normally. The hook collects fees (for exactInput
swaps). The hook's afterSwap fires but rebalancing is a no-op.

As long as the price stays within band 0's range, everything works. If price
exits band 0:
- No more LP → very high slippage → practical trading stops
- The hook thinks it transitioned but no liquidity actually moved
- Price would bounce back into band 0 due to lack of liquidity above it

For the current low-volume prototype stage, this is likely fine — the price
hasn't moved enough to exit band 0. But it means the bonding curve approximation
(the whole point of the band system) doesn't actually work.

### R-05: What about the V1 `TrinityHook.sol` (bonding curve version)?

**Re-examined:** This contract is in the repo but NOT deployed (V5 is deployed).
It has a completely different architecture (replaces AMM with custom bonding
curve math). Key issues:
- `try manager.take(...) {} catch {}` — silently swallows take failures,
  allowing the Quoter to simulate but also meaning real swap failures are silent
- Uses `Math.sqrt` on potentially large values — should be safe with OZ's
  implementation
- `_calcTokensOut` and `_calcQuoteOut` do WAD math — need careful review for
  precision but not relevant since this hook isn't deployed

**Not in scope for deployed contract audit.** Noted for completeness.

---

## Summary — All Findings by Severity

| ID | Severity | Finding | Fixable in Current Deploy? |
|---|---|---|---|
| C-01 + R-02 | **CRITICAL** | Initial LP owned by LPSeeder, not hook. Hook cannot manage it. Band rebalancing is completely non-functional. | NO — requires redeploy |
| H-01 | **HIGH** | `withdrawLP` always reverts (no unlock context). No emergency LP recovery. | NO — requires redeploy |
| H-02 | **HIGH** | exactOutput swaps bypass 1% fee entirely. Trivially exploitable. | NO — requires redeploy |
| H-03 | **HIGH** | `_computeLiquidity` uint256 overflow in intermediate multiplication. | NO — requires redeploy |
| H-04 | **HIGH** | Single-step band transition. Large swaps desync activeBand from price. | NO — requires redeploy |
| C-02 | **HIGH** | Initial LP permanently locked in PM. No recovery mechanism exists. | NO — locked forever |
| C-03 | **HIGH** | exactOutput + multi-call = fee-free band manipulation. | NO — requires redeploy |
| M-01 | **MEDIUM** | `registerPool` never sets `initialized = true`. Double-call appends duplicate bands. | MITIGATED (ownership at multisig) |
| M-02 | **MEDIUM** | Dead refund code in `_addLiquidityToBand`. Excess tokens strand as PM credits. | NO — requires redeploy |
| M-03 | **MEDIUM** | `band.liquidity` overwrites instead of accumulating. Tracking desync on re-entry. | NO — requires redeploy |
| M-04 | **MEDIUM** | TrinityRouter doesn't refund excess pre-settle. | YES (if router is used) |
| M-05 | **MEDIUM** | TrinityRouter `sellTriForETH` reentrancy surface via ETH transfer. | YES (if router is used) |
| L-01 | LOW | Duplicate BeforeSwapDelta import. | Cosmetic |
| L-02 | LOW | Unused `toBalanceDelta` import. | Cosmetic |
| L-03 | LOW | No input validation in `registerPool`. | MITIGATED (ownership at multisig) |
| L-04 | LOW | No ReentrancyGuard on hook. PM lock covers primary path. | MITIGATED |
| L-05 | LOW | `int128` cast overflow on impossibly large fee. | Theoretical |
| L-06 | LOW | External LP bypasses band tracking. | By design |
| L-07 | LOW | Burn to `0xdead` doesn't reduce `totalSupply()`. | Cosmetic / by design |
| L-08 | LOW | Router delta cast produces wrong value on abnormal swap. | Theoretical |
| L-09 | LOW | Deploy script precision loss in liquidity calc (truncating division). | Negligible |
| C-04 | INFO | No afterInitialize hook — LP seeding design constraint. | By design |
| C-05 | LOW | Fee recipient DoS if changed to reverting contract. | MITIGATED (multisig) |
| C-06 | LOW-MED | Flash loan band manipulation (theoretical with broken rebalancing). | Theoretical |
| R-01 | UNKNOWN | Excess settle in `_addLiquidityToBand` may cause unlock to revert on real band transitions. Untested. | Needs testing |

---

## Recommendations for V6

A contract redeploy is required to fix any HIGH or CRITICAL issue. The minimum
viable V6 should address:

1. **Hook-owned LP seeding**: Add an `ownerSeedBand(poolKey, bandIndex, uint128 liquidity)` function that seeds LP within an unlock context, so the hook owns the position and tracks `band.liquidity` correctly.

2. **Fix fee bypass**: Charge fee on exactOutput swaps too, or revert on exactOutput (like V1 does with `ExactOutputNotSupported`).

3. **Fix `_computeLiquidity` overflow**: Use `FullMath.mulDiv` from Uniswap libraries, or adopt the deploy script's divide-first pattern.

4. **Multi-band transition**: Change `if` to a bounded `while` loop in `_checkAndRebalance`.

5. **Fix `withdrawLP`**: Wrap in an unlock context (add a function that calls `manager.unlock()` with callback data for LP removal).

6. **Set `initialized = true`** in `registerPool`.

7. **Fix refund logic in `_addLiquidityToBand`**: Correctly handle delta signs from `modifyLiquidity`, or settle only the exact amount needed rather than the full balance.
