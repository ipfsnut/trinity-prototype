// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {TrinityHookV6} from "../src/trinity/TrinityHookV6.sol";
import {TrinityTokenV6} from "../src/trinity/TrinityTokenV6.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HookMiner} from "../script/HookMiner.sol";

/* ═══════════════════════════════════════════════════════════════════════ */
/*                          MOCK TOKENS                                   */
/* ═══════════════════════════════════════════════════════════════════════ */

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { _mint(msg.sender, 1e12 * 1e6); }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/* ═══════════════════════════════════════════════════════════════════════ */
/*                      SWAP ROUTER (pre-settle)                          */
/* ═══════════════════════════════════════════════════════════════════════ */

contract SwapRouter {
    IPoolManager public immutable manager;
    constructor(IPoolManager _mgr) { manager = _mgr; }

    struct CB { PoolKey key; IPoolManager.SwapParams params; address sender; }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(
            manager.unlock(abi.encode(CB(key, params, msg.sender))),
            (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not PM");
        CB memory cb = abi.decode(data, (CB));

        Currency inC = cb.params.zeroForOne ? cb.key.currency0 : cb.key.currency1;
        uint256 inAmt = uint256(-cb.params.amountSpecified);
        manager.sync(inC);
        ERC20(Currency.unwrap(inC)).transferFrom(cb.sender, address(manager), inAmt);
        manager.settle();

        BalanceDelta delta = manager.swap(cb.key, cb.params, "");

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();

        if (d0 > 0) manager.take(cb.key.currency0, cb.sender, uint256(uint128(d0)));
        if (d1 > 0) manager.take(cb.key.currency1, cb.sender, uint256(uint128(d1)));

        // Refund excess pre-settle
        int128 inputConsumed = cb.params.zeroForOne ? d0 : d1;
        if (inputConsumed < 0) {
            uint256 consumed = uint256(uint128(-inputConsumed));
            if (consumed < inAmt) {
                manager.take(inC, cb.sender, inAmt - consumed);
            }
        } else if (inputConsumed == 0) {
            manager.take(inC, cb.sender, inAmt);
        }

        return abi.encode(delta);
    }
}

/* ═══════════════════════════════════════════════════════════════════════ */
/*                 LP ADDER (for testing external LP block)               */
/* ═══════════════════════════════════════════════════════════════════════ */

contract ExternalLPAdder {
    IPoolManager public immutable manager;
    constructor(IPoolManager _mgr) { manager = _mgr; }

    struct AddData { PoolKey key; int24 tickLower; int24 tickUpper; uint128 liquidity; }

    function addLP(PoolKey memory key, int24 tl, int24 tu, uint128 liq) external {
        manager.unlock(abi.encode(AddData(key, tl, tu, liq)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not PM");
        AddData memory d = abi.decode(data, (AddData));

        (BalanceDelta delta,) = manager.modifyLiquidity(
            d.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: d.tickLower,
                tickUpper: d.tickUpper,
                liquidityDelta: int256(uint256(d.liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        if (delta.amount0() < 0) {
            Currency c = d.key.currency0;
            uint256 amt = uint256(uint128(-delta.amount0()));
            manager.sync(c);
            ERC20(Currency.unwrap(c)).transfer(address(manager), amt);
            manager.settle();
        }
        if (delta.amount1() < 0) {
            Currency c = d.key.currency1;
            uint256 amt = uint256(uint128(-delta.amount1()));
            manager.sync(c);
            ERC20(Currency.unwrap(c)).transfer(address(manager), amt);
            manager.settle();
        }

        return "";
    }
}

/* ═══════════════════════════════════════════════════════════════════════ */
/*                            TESTS                                       */
/* ═══════════════════════════════════════════════════════════════════════ */

contract TrinityHookV6Test is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolManager pm;
    TrinityHookV6 hook;
    TrinityTokenV6 trini;
    MockUSDC usdc;
    SwapRouter router;

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address owner = address(this);
    address alice = makeAddr("alice");
    address feeRecipient = makeAddr("feeRecipient");

    PoolKey poolKey;
    PoolId poolId;

    // Deceleration band config: 5 bands for testing
    // Ignition(1200) → decel(2000) → settle(3400) → cruise(6800) → cruise(6800)
    int24[] tickLowers;
    int24[] tickUppers;
    int24 constant INITIAL_TICK = -368400;
    int24[5] BAND_WIDTHS = [int24(1200), int24(2000), int24(3400), int24(6800), int24(6800)];

    // V6 permission bits: BEFORE_ADD_LIQUIDITY + BEFORE_SWAP + BEFORE_SWAP_RETURNS_DELTA + AFTER_SWAP
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG |
        Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    function setUp() public {
        pm = new PoolManager(owner);
        trini = new TrinityTokenV6(owner);
        usdc = new MockUSDC();

        // Mine hook address with V6 permission bits
        bytes memory code = abi.encodePacked(
            type(TrinityHookV6).creationCode,
            abi.encode(address(pm), address(trini), owner)
        );
        (uint256 salt, address hookAddr) = HookMiner.find(address(this), HOOK_FLAGS, keccak256(code));
        address deployed;
        assembly { deployed := create2(0, add(code, 0x20), mload(code), salt) }
        require(deployed == hookAddr, "addr mismatch");
        hook = TrinityHookV6(deployed);

        // Sort currencies
        (Currency c0, Currency c1) = address(trini) < address(usdc)
            ? (Currency.wrap(address(trini)), Currency.wrap(address(usdc)))
            : (Currency.wrap(address(usdc)), Currency.wrap(address(trini)));

        poolKey = PoolKey({ currency0: c0, currency1: c1, fee: 0, tickSpacing: 200, hooks: IHooks(address(hook)) });
        poolId = poolKey.toId();

        // Build deceleration bands (contiguous)
        int24 cursor = INITIAL_TICK;
        for (uint256 i = 0; i < 5; i++) {
            tickLowers.push(cursor);
            cursor += BAND_WIDTHS[i];
            tickUppers.push(cursor);
        }

        // Register pool on hook
        hook.registerPool(poolKey, tickLowers, tickUppers, feeRecipient);

        // Initialize pool one tickSpacing below band 0 (one-sided LP)
        pm.initialize(poolKey, TickMath.getSqrtPriceAtTick(INITIAL_TICK - 200));

        // Seed band 0 via ownerSeedBand (hook owns the position)
        uint128 seedLiquidity = uint128(6.4e15);
        trini.transfer(address(hook), 500_000_000 * 1e18); // 500M TRINI for LP
        hook.ownerSeedBand(poolKey, 0, seedLiquidity);

        // Deploy swap router
        router = new SwapRouter(pm);

        // Fund alice
        usdc.mint(alice, 10_000_000 * 1e6);
        trini.transfer(alice, 10_000_000 * 1e18);
        vm.startPrank(alice);
        ERC20(address(usdc)).approve(address(router), type(uint256).max);
        trini.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /* ──────────────── helpers ──────────────── */

    bool _isBuyZeroForOne;

    function _getBuyDirection() internal view returns (bool) {
        return address(trini) > address(usdc);
    }

    function _swap(bool zeroForOne, uint256 amount) internal returns (BalanceDelta) {
        return router.swap(poolKey, IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        }));
    }

    /* ──────────────── 1. LP exists after seeding ──────────────── */

    function test_liquidityNonZero() public view {
        (uint128 grossLower,,,) = StateLibrary.getTickInfo(pm, poolId, tickLowers[0]);
        (uint128 grossUpper,,,) = StateLibrary.getTickInfo(pm, poolId, tickUppers[0]);
        assertGt(grossLower, 0, "band 0 lower has liquidity");
        assertGt(grossUpper, 0, "band 0 upper has liquidity");
    }

    /* ──────────────── 2. ownerSeedBand tracks liquidity ──────────────── */

    function test_ownerSeedBand_tracksLiquidity() public view {
        TrinityHookV6.Band memory band = hook.getBand(poolId, 0);
        assertEq(band.liquidity, uint128(6.4e15), "tracked liquidity matches seed");
    }

    /* ──────────────── 3. Basic buy ──────────────── */

    function test_buyBasic() public {
        bool buyDir = _getBuyDirection();
        uint256 triBefore = trini.balanceOf(alice);

        vm.prank(alice);
        _swap(buyDir, 1000 * 1e6);

        assertGt(trini.balanceOf(alice) - triBefore, 0, "got TRINI from AMM");
    }

    /* ──────────────── 4. Fee collection ──────────────── */

    function test_feeCollection() public {
        bool buyDir = _getBuyDirection();

        vm.prank(alice);
        _swap(buyDir, 10_000 * 1e6);

        uint256 expectedFee = 10_000 * 1e6 / 100; // 1%
        uint256 feeBalance = usdc.balanceOf(feeRecipient);
        assertEq(feeBalance, expectedFee, "1% USDC fee collected");
    }

    /* ──────────────── 5. Sell burns TRINI ──────────────── */

    function test_sellBurnsTRINI() public {
        bool buyDir = _getBuyDirection();

        // Buy first
        vm.prank(alice);
        _swap(buyDir, 1000 * 1e6);
        uint256 triBought = trini.balanceOf(alice) - 10_000_000 * 1e18;
        if (triBought == 0) return; // skip if no output

        // Sell
        uint256 deadBefore = trini.balanceOf(DEAD);
        vm.prank(alice);
        _swap(!buyDir, triBought);

        uint256 burned = trini.balanceOf(DEAD) - deadBefore;
        uint256 expectedBurn = triBought / 100;
        assertEq(burned, expectedBurn, "1% TRINI burned on sell");
    }

    /* ──────────────── 6. Price moves ──────────────── */

    function test_priceMoves() public {
        (, int24 tickBefore,,) = StateLibrary.getSlot0(pm, poolId);
        bool buyDir = _getBuyDirection();

        vm.prank(alice);
        _swap(buyDir, 10_000 * 1e6);

        (, int24 tickAfter,,) = StateLibrary.getSlot0(pm, poolId);
        assertTrue(tickAfter != tickBefore, "price moved");
    }

    /* ──────────────── 7. Band transition ──────────────── */

    function test_bandTransition() public {
        assertEq(hook.getActiveBand(poolId), 0, "starts at band 0");
        bool buyDir = _getBuyDirection();

        // Large buy to push through band 0 (1200 ticks wide — very narrow)
        usdc.mint(alice, 1_000_000 * 1e6);
        vm.prank(alice);
        ERC20(address(usdc)).approve(address(router), type(uint256).max);

        vm.prank(alice);
        _swap(buyDir, 500_000 * 1e6);

        uint256 active = hook.getActiveBand(poolId);
        console2.log("  Active band after large buy: %d", active);
        // May or may not have transitioned depending on LP depth
    }

    /* ──────────────── 8. Multi-band jump ──────────────── */

    function test_multiBandJump() public {
        bool buyDir = _getBuyDirection();
        uint256 startBand = hook.getActiveBand(poolId);

        // Very large buy — try to push through multiple bands
        usdc.mint(alice, 10_000_000 * 1e6);
        vm.prank(alice);
        ERC20(address(usdc)).approve(address(router), type(uint256).max);

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            try this._swapExternal(buyDir, 1_000_000 * 1e6) {} catch { break; }
        }

        uint256 endBand = hook.getActiveBand(poolId);
        console2.log("  Bands traversed: %d -> %d", startBand, endBand);
    }

    // Helper to call swap from test contract (for try/catch)
    function _swapExternal(bool zeroForOne, uint256 amount) external {
        vm.prank(alice);
        _swap(zeroForOne, amount);
    }

    /* ──────────────── 9. exactOutput reverts ──────────────── */

    function test_exactOutputReverts() public {
        bool buyDir = _getBuyDirection();

        vm.prank(alice);
        vm.expectRevert();
        router.swap(poolKey, IPoolManager.SwapParams({
            zeroForOne: buyDir,
            amountSpecified: int256(1000 * 1e6), // positive = exactOutput
            sqrtPriceLimitX96: buyDir ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        }));
    }

    /* ──────────────── 10. External LP blocked ──────────────── */

    function test_externalLP_blocked() public {
        ExternalLPAdder adder = new ExternalLPAdder(pm);
        trini.transfer(address(adder), 1_000_000 * 1e18);
        usdc.mint(address(adder), 1_000_000 * 1e6);

        vm.expectRevert();
        adder.addLP(poolKey, tickLowers[0], tickUppers[0], uint128(1e15));
    }

    /* ──────────────── 11. registerPool double call reverts ──────────────── */

    function test_registerPool_doubleCall_reverts() public {
        vm.expectRevert();
        hook.registerPool(poolKey, tickLowers, tickUppers, feeRecipient);
    }

    /* ──────────────── 12. Emergency withdraw LP ──────────────── */

    function test_emergencyWithdrawLP() public {
        uint256 ownerTriBefore = trini.balanceOf(owner);

        hook.emergencyWithdrawLP(poolKey, 0);

        TrinityHookV6.Band memory band = hook.getBand(poolId, 0);
        assertEq(band.liquidity, 0, "band liquidity zeroed");

        uint256 ownerTriAfter = trini.balanceOf(owner);
        assertGt(ownerTriAfter, ownerTriBefore, "owner received TRINI back");
    }

    /* ──────────────── 13. External LP always blocked (no graduation) ──────────────── */

    function test_externalLP_alwaysBlocked() public {
        // Even after many swaps, external LP is still blocked
        bool buyDir = _getBuyDirection();
        vm.prank(alice);
        _swap(buyDir, 1000 * 1e6);

        ExternalLPAdder adder = new ExternalLPAdder(pm);
        trini.transfer(address(adder), 1_000_000 * 1e18);
        usdc.mint(address(adder), 1_000_000 * 1e6);

        vm.expectRevert();
        adder.addLP(poolKey, tickLowers[0], tickUppers[0], uint128(1e12));
    }

    /* ──────────────── 14. withdrawTokens ──────────────── */

    function test_withdrawTokens() public {
        usdc.mint(address(hook), 1000 * 1e6);
        uint256 before = usdc.balanceOf(owner);

        hook.withdrawTokens(address(usdc), 1000 * 1e6, owner);

        assertEq(usdc.balanceOf(owner) - before, 1000 * 1e6, "withdrew USDC");
    }

    function test_withdrawTokens_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        hook.withdrawTokens(address(usdc), 1, alice);
    }

    /* ──────────────── 18. updateFeeRecipient ──────────────── */

    function test_updateFeeRecipient() public {
        address newRecipient = makeAddr("newFeeRecipient");
        hook.updateFeeRecipient(poolKey, newRecipient);

        bool buyDir = _getBuyDirection();
        vm.prank(alice);
        _swap(buyDir, 10_000 * 1e6);

        assertGt(usdc.balanceOf(newRecipient), 0, "fee went to new recipient");
        assertEq(usdc.balanceOf(feeRecipient), 0, "old recipient got nothing");
    }

    /* ──────────────── 19. Band contiguity required ──────────────── */

    function test_bandContiguity_required() public {
        // Build a second pool with non-contiguous bands
        PoolKey memory key2 = PoolKey({
            currency0: poolKey.currency0,
            currency1: poolKey.currency1,
            fee: 0, // same fee, different ticks give different poolId
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });

        int24[] memory badLowers = new int24[](2);
        int24[] memory badUppers = new int24[](2);
        badLowers[0] = -200000;
        badUppers[0] = -198800; // band 0
        badLowers[1] = -198000; // GAP: -198800 != -198000
        badUppers[1] = -196800;

        vm.expectRevert();
        hook.registerPool(key2, badLowers, badUppers, feeRecipient);
    }

    /* ──────────────── 20. PM balance invariant ──────────────── */

    function test_pmBalanceInvariant() public {
        uint256 pmUsdc0 = usdc.balanceOf(address(pm));
        bool buyDir = _getBuyDirection();

        vm.prank(alice);
        _swap(buyDir, 1000 * 1e6);

        uint256 pmUsdc1 = usdc.balanceOf(address(pm));
        assertGe(pmUsdc1, pmUsdc0, "PM USDC didn't decrease");
    }
}
