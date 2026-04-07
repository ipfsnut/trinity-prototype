// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TrinityTokenV6} from "../src/trinity/TrinityTokenV6.sol";
import {TrinityHookV6} from "../src/trinity/TrinityHookV6.sol";
import {ChaosLPHub} from "../src/ChaosLPHub.sol";
import {RewardGauge} from "../src/RewardGauge.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {HookMiner} from "./HookMiner.sol";
import {TokenMiner} from "./TokenMiner.sol";

contract HookFactory {
    function deploy(bytes memory bytecode, uint256 salt) external returns (address addr) {
        assembly { addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt) }
        require(addr != address(0), "CREATE2 failed");
    }
}

/// @title DeployTrinityV6
/// @notice Full deployment: token + hook + pool init + seed + staking.
///
///   Key differences from V5:
///     - Hook has BEFORE_ADD_LIQUIDITY bit (blocks external LP)
///     - LP seeded via hook.ownerSeedBand() (hook owns positions)
///     - Deceleration band schedules (ignition → settle → cruise)
///     - 50/33/17 allocation: 450M USDC, 297M WETH, 153M ChaosLP
///     - $25K starting FDV ($0.000025 base price)
///
///   Usage:
///     forge script script/DeployTrinityV6.s.sol --tc DeployTrinityV6 \
///       --rpc-url base --broadcast --verify --slow -vvvv
contract DeployTrinityV6 is Script {
    // -- V4 infra on Base --
    IPoolManager constant PM = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

    // -- Quote assets --
    address constant USDC    = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH    = 0x4200000000000000000000000000000000000006;
    address constant CHAOSLP = 0x8454d062506a27675706148ECDd194E45e44067a;
    address constant MULTISIG = 0xb7DD467A573809218aAE30EB2c60e8AE3a9198a0;

    // -- V6 hook permission bits --
    // BEFORE_ADD_LIQUIDITY(11) + BEFORE_SWAP(7) + BEFORE_SWAP_RETURNS_DELTA(3) + AFTER_SWAP(6)
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
        Hooks.BEFORE_SWAP_FLAG |
        Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
        Hooks.AFTER_SWAP_FLAG
    );

    // -- Token allocation (50/33/17 split) --
    uint256 constant TRINI_USDC_POOL = 450_000_000 * 1e18;
    uint256 constant TRINI_WETH_POOL = 297_000_000 * 1e18;
    uint256 constant TRINI_CLP_POOL  = 153_000_000 * 1e18;
    uint256 constant TREASURY       = 100_000_000 * 1e18;

    // -- Base price: $0.000025 --
    // USDC pool: TRINI(18)/USDC(6). 0.000025 USDC/TRINI → tick ≈ -382,200
    int24 constant USDC_TICK_BASE = -382200;
    // WETH pool: TRINI(18)/WETH(18). $0.000025 at $2,220/ETH → tick ≈ -183,000
    int24 constant WETH_TICK_BASE = -183000;
    // CLP pool: TRINI(18)/CLP(18). $0.000025 at CLP≈$2.56e-8 → tick ≈ 68,800
    int24 constant CLP_TICK_BASE = 68800;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("");
        console2.log("  Trinity V6 Deployment");
        console2.log("  Deployer: ", deployer);

        vm.startBroadcast(pk);

        // ---- Phase 1: CREATE2 factory ----
        HookFactory factory = new HookFactory();

        // ---- Phase 2: Token via CREATE2 (must be below WETH for currency0 ordering) ----
        bytes memory tokenCode = abi.encodePacked(
            type(TrinityTokenV6).creationCode,
            abi.encode(deployer)
        );
        (uint256 tokenSalt, address tokenAddr) = TokenMiner.find(
            address(factory), WETH, keccak256(tokenCode)
        );
        address tokenDeployed = factory.deploy(tokenCode, tokenSalt);
        require(tokenDeployed == tokenAddr, "token addr mismatch");
        TrinityTokenV6 trini = TrinityTokenV6(tokenDeployed);
        console2.log("  TRINI:", address(trini));
        require(address(trini) < WETH, "TRINI must be below WETH");

        // ---- Phase 3: Hook via CREATE2 (V6 permission bits) ----
        bytes memory hookCode = abi.encodePacked(
            type(TrinityHookV6).creationCode,
            abi.encode(address(PM), address(trini), deployer)
        );
        (uint256 hookSalt, address hookAddr) = HookMiner.find(
            address(factory), HOOK_FLAGS, keccak256(hookCode)
        );
        address hookDeployed = factory.deploy(hookCode, hookSalt);
        require(hookDeployed == hookAddr, "hook addr mismatch");
        TrinityHookV6 hook = TrinityHookV6(hookDeployed);
        console2.log("  Hook: ", hookAddr);

        // ---- Phase 4: Register + init pools ----
        _registerAndInit(trini, hook, USDC, USDC_TICK_BASE, _usdcBandWidths(), "USDC");
        _registerAndInit(trini, hook, WETH, WETH_TICK_BASE, _wethBandWidths(), "WETH");
        _registerAndInit(trini, hook, CHAOSLP, CLP_TICK_BASE, _clpBandWidths(), "CLP");

        // ---- Phase 5: Seed LP via hook.ownerSeedBand() ----
        // Transfer TRINI per-pool (NOT in bulk) to prevent inter-seeding
        // token drain: if all TRINI is in the hook when pool 1 is seeded,
        // an attacker can trigger a rebalance that sweeps pool 2/3's TRINI.
        trini.transfer(address(hook), TRINI_USDC_POOL);
        _seedPool(hook, address(trini), USDC, hookAddr, USDC_TICK_BASE, _usdcBandWidths(), TRINI_USDC_POOL, "USDC");

        trini.transfer(address(hook), TRINI_WETH_POOL);
        _seedPool(hook, address(trini), WETH, hookAddr, WETH_TICK_BASE, _wethBandWidths(), TRINI_WETH_POOL, "WETH");

        trini.transfer(address(hook), TRINI_CLP_POOL);
        _seedPool(hook, address(trini), CHAOSLP, hookAddr, CLP_TICK_BASE, _clpBandWidths(), TRINI_CLP_POOL, "CLP");

        console2.log("  LP seeded (hook owns all positions)");

        // ---- Phase 6: Treasury ----
        uint256 remaining = trini.balanceOf(deployer);
        trini.transfer(MULTISIG, remaining);
        console2.log("  Treasury: %d TRINI -> multisig", remaining / 1e18);

        // ---- Phase 7: Staking ----
        ChaosLPHub hub = new ChaosLPHub(address(trini), address(trini), deployer);
        RewardGauge wethGauge = new RewardGauge(address(hub), WETH, deployer);
        hub.addExtraReward(address(wethGauge));
        hub.transferOwnership(MULTISIG);
        wethGauge.transferOwnership(MULTISIG);
        console2.log("  Hub: ", address(hub));
        console2.log("  WETH Gauge: ", address(wethGauge));

        // ---- Phase 8: Transfer hook ownership to multisig ----
        hook.transferOwnership(MULTISIG);

        vm.stopBroadcast();

        console2.log("");
        console2.log("  V6 DEPLOYMENT COMPLETE");
        console2.log("  Hook owns all LP. Curves are permanent. No graduation.");
        console2.log("");
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                   DECELERATION BAND SCHEDULES                     */
    /* ══════════════════════════════════════════════════════════════════ */

    /// @dev USDC — fast deceleration (16 bands)
    /// Ignition(1200) → decel(2000,3400) → cruise(6800×3) → anchor(10000×10)
    function _usdcBandWidths() internal pure returns (int24[] memory) {
        int24[] memory w = new int24[](16);
        w[0]  = 1200;   // ignition
        w[1]  = 2000;   // decel
        w[2]  = 3400;   // settle
        w[3]  = 6800;   // cruise
        w[4]  = 6800;
        w[5]  = 6800;
        w[6]  = 10000;  // anchor
        w[7]  = 10000;
        w[8]  = 10000;
        w[9]  = 10000;
        w[10] = 10000;
        w[11] = 10000;
        w[12] = 10000;
        w[13] = 10000;
        w[14] = 10000;
        w[15] = 10000;
        return w;
    }

    /// @dev WETH — medium deceleration (15 bands)
    /// Ignition(1200) → decel(2000,3400) → settle(3400×3) → cruise(6800×4) → tail(10000×5)
    function _wethBandWidths() internal pure returns (int24[] memory) {
        int24[] memory w = new int24[](15);
        w[0]  = 1200;   // ignition
        w[1]  = 2000;   // decel
        w[2]  = 3400;   // settle
        w[3]  = 3400;
        w[4]  = 3400;
        w[5]  = 3400;
        w[6]  = 6800;   // cruise
        w[7]  = 6800;
        w[8]  = 6800;
        w[9]  = 6800;
        w[10] = 10000;  // tail
        w[11] = 10000;
        w[12] = 10000;
        w[13] = 10000;
        w[14] = 10000;
        return w;
    }

    /// @dev ChaosLP — slow deceleration (15 bands)
    /// Ignition(1200) → slow decel(2000×2) → steep(3400×7) → cruise(6800×3) → tail(10000×2)
    function _clpBandWidths() internal pure returns (int24[] memory) {
        int24[] memory w = new int24[](15);
        w[0]  = 1200;   // ignition
        w[1]  = 2000;   // slow decel
        w[2]  = 2000;
        w[3]  = 3400;   // still steep
        w[4]  = 3400;
        w[5]  = 3400;
        w[6]  = 3400;
        w[7]  = 3400;
        w[8]  = 3400;
        w[9]  = 3400;
        w[10] = 6800;   // late cruise
        w[11] = 6800;
        w[12] = 6800;
        w[13] = 10000;  // tail
        w[14] = 10000;
        return w;
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                        INTERNAL HELPERS                           */
    /* ══════════════════════════════════════════════════════════════════ */

    function _registerAndInit(
        TrinityTokenV6 trini,
        TrinityHookV6 hook,
        address quote,
        int24 tickBase,
        int24[] memory bandWidths,
        string memory name
    ) internal {
        // Build contiguous band arrays from widths
        uint256 n = bandWidths.length;
        int24[] memory lowers = new int24[](n);
        int24[] memory uppers = new int24[](n);
        int24 cursor = tickBase;
        for (uint256 i = 0; i < n; i++) {
            lowers[i] = cursor;
            cursor += bandWidths[i];
            uppers[i] = cursor;
        }

        PoolKey memory key = _makeKey(address(trini), quote, address(hook));
        hook.registerPool(key, lowers, uppers, MULTISIG);

        // Initialize pool one tickSpacing below band 0 (one-sided LP)
        int24 initTick = tickBase - 200;
        PM.initialize(key, TickMath.getSqrtPriceAtTick(initTick));

        console2.log("  Pool %s initialized, %d bands", name, n);
    }

    function _seedPool(
        TrinityHookV6 hook,
        address triniAddr,
        address quote,
        address hookAddr,
        int24 tickBase,
        int24[] memory bandWidths,
        uint256 triniAmount,
        string memory name
    ) internal {
        PoolKey memory key = _makeKey(triniAddr, quote, hookAddr);

        // Compute liquidity from TRINI amount for band 0
        int24 tl = tickBase;
        int24 tu = tickBase + bandWidths[0];
        uint128 liquidity = _computeLiquidityFromAmount0(tl, tu, triniAmount);

        console2.log("  %s liquidity: %d", name, uint256(liquidity));
        hook.ownerSeedBand(key, 0, liquidity);
        console2.log("  Seeded %s pool", name);
    }

    /// @dev Compute liquidity L from amount of currency0 (TRINI) for a one-sided
    ///      position below the range (currentTick < tickLower).
    ///      L = amount0 * sqrtLower * sqrtUpper / (sqrtUpper - sqrtLower) / 2^96
    function _computeLiquidityFromAmount0(
        int24 tickLower,
        int24 tickUpper,
        uint256 targetAmount0
    ) internal pure returns (uint128) {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        uint256 diff = uint256(sqrtUpper) - uint256(sqrtLower);
        uint256 intermediate = FullMath.mulDiv(
            targetAmount0, uint256(sqrtLower), diff
        );
        uint256 L = FullMath.mulDiv(intermediate, uint256(sqrtUpper), 1 << 96);

        require(L > 0 && L <= type(uint128).max, "L overflow or zero");
        return uint128(L);
    }

    function _makeKey(address t, address q, address h) internal pure returns (PoolKey memory) {
        (address c0, address c1) = t < q ? (t, q) : (q, t);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, 200, IHooks(h));
    }
}
