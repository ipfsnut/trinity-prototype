// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TrinityHookV7} from "../src/trinity/TrinityHookV7.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {HookMiner} from "./HookMiner.sol";

contract HookFactory {
    function deploy(bytes memory bytecode, uint256 salt) external returns (address addr) {
        assembly { addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt) }
        require(addr != address(0), "CREATE2 failed");
    }
}

/// @title DeployTrinityV7
/// @notice Deploy two single-pool V7 hooks: TRINI/Clanker and TRINI/WETH.
///
///   Each hook is an independent 5% fee burn engine. The existing V6 hook keeps
///   running USDC (1%) and WETH (1%) as deep trading venues. V7 pools layer on
///   top as responsive arb surfaces with higher burn extraction.
///
///   This script deploys and configures both hooks but does NOT fund them.
///   Funding is done via multisig after deployment:
///     1. Transfer TRINI to each hook address
///     2. Call ownerSeedBand(key, 0, liquidity) on each hook
///
///   Usage:
///     forge script script/DeployTrinityV7.s.sol --tc DeployTrinityV7 \
///       --rpc-url base --broadcast --verify --slow -vvvv
contract DeployTrinityV7 is Script {
    // -- V4 infra on Base --
    IPoolManager constant PM = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

    // -- Tokens --
    address constant TRINI   = 0x17790eFD4896A981Db1d9607A301BC4F7407F3dF;
    address constant CLANKER = 0x1bc0c42215582d5A085795f4baDbaC3ff36d1Bcb;
    address constant WETH    = 0x4200000000000000000000000000000000000006;
    address constant MULTISIG = 0xb7DD467A573809218aAE30EB2c60e8AE3a9198a0;

    // -- V7 hook permission bits (same as V6) --
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
        Hooks.BEFORE_SWAP_FLAG |
        Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
        Hooks.AFTER_SWAP_FLAG
    );

    // -- Allocations --
    uint256 constant TRINI_CLANKER = 84_000_000 * 1e18;
    uint256 constant TRINI_WETH    = 50_000_000 * 1e18;

    // -- Tick bases (TRINI is currency0 in both pools, all 18 decimals) --
    // Clanker: $0.0000253 TRINI at $26.07 Clanker
    int24 constant CLANKER_TICK_BASE = -138400;
    // WETH: $0.0000253 TRINI at $2,188 ETH
    int24 constant WETH_TICK_BASE = -182800;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("");
        console2.log("  Trinity V7 Deployment (2 hooks)");
        console2.log("  Deployer: ", deployer);

        // Verify address ordering (TRINI must be currency0 in all pools)
        require(TRINI < CLANKER, "TRINI must be < CLANKER");
        require(TRINI < WETH,    "TRINI must be < WETH");

        vm.startBroadcast(pk);

        // Shared factory
        HookFactory factory = new HookFactory();

        // -- Hook 1: TRINI/Clanker --
        console2.log("  --- Clanker Pool ---");
        TrinityHookV7 clankerHook = _deployHook(factory, deployer);
        _registerAndInit(clankerHook, CLANKER, CLANKER_TICK_BASE, _clankerBands());
        console2.log("  Clanker hook: ", address(clankerHook));

        // -- Hook 2: TRINI/WETH --
        console2.log("  --- WETH Pool ---");
        TrinityHookV7 wethHook = _deployHook(factory, deployer);
        _registerAndInit(wethHook, WETH, WETH_TICK_BASE, _wethBands());
        console2.log("  WETH hook:    ", address(wethHook));

        // -- Transfer ownership to multisig --
        clankerHook.transferOwnership(MULTISIG);
        wethHook.transferOwnership(MULTISIG);

        vm.stopBroadcast();

        // -- Log seeding instructions --
        console2.log("");
        console2.log("  V7 DEPLOYMENT COMPLETE - 2 hooks deployed");
        console2.log("  All pools initialized. LP NOT YET SEEDED.");
        console2.log("");
        console2.log("  MULTISIG SEEDING (per hook):");
        console2.log("    1. Transfer TRINI to hook address");
        console2.log("    2. Call ownerSeedBand(key, 0, liquidity)");
        console2.log("");

        _logSeedParams("Clanker", address(clankerHook), CLANKER, CLANKER_TICK_BASE, _clankerBands(), TRINI_CLANKER);
        _logSeedParams("WETH",    address(wethHook),    WETH,    WETH_TICK_BASE,    _wethBands(),    TRINI_WETH);
    }

    /* ================================================================ */
    /*                   DECELERATION BAND SCHEDULES                     */
    /* ================================================================ */

    /// @dev Clanker: 9 bands, wide ignition (22%).
    ///      Clanker swings 10-20% routinely. A narrow ignition band would
    ///      churn through band transitions on normal volatility.
    ///      2000 -> 3400x2 -> 6800x3 -> 10000x3
    ///      Total: 59,200 ticks = ~372x price range.
    function _clankerBands() internal pure returns (int24[] memory) {
        int24[] memory w = new int24[](9);
        w[0] = 2000;    // ignition (22%)
        w[1] = 3400;    // settle
        w[2] = 3400;
        w[3] = 6800;    // cruise
        w[4] = 6800;
        w[5] = 6800;
        w[6] = 10000;   // tail
        w[7] = 10000;
        w[8] = 10000;
        return w;
    }

    /// @dev WETH: 9 bands, standard ignition (12.7%).
    ///      ETH moves 2-8% typically. The 5% fee dead zone already filters
    ///      most routine moves, so Band 0 only sees 6%+ moves.
    ///      1200 -> 2000 -> 3400x2 -> 6800x3 -> 10000x2
    ///      Total: 50,400 ticks = ~154x price range.
    function _wethBands() internal pure returns (int24[] memory) {
        int24[] memory w = new int24[](9);
        w[0] = 1200;    // ignition (12.7%)
        w[1] = 2000;    // decel
        w[2] = 3400;    // settle
        w[3] = 3400;
        w[4] = 6800;    // cruise
        w[5] = 6800;
        w[6] = 6800;
        w[7] = 10000;   // tail
        w[8] = 10000;
        return w;
    }

    /* ================================================================ */
    /*                        INTERNAL HELPERS                           */
    /* ================================================================ */

    function _deployHook(HookFactory factory, address deployer) internal returns (TrinityHookV7) {
        bytes memory hookCode = abi.encodePacked(
            type(TrinityHookV7).creationCode,
            abi.encode(address(PM), TRINI, deployer)
        );
        (uint256 hookSalt, address hookAddr) = HookMiner.find(
            address(factory), HOOK_FLAGS, keccak256(hookCode)
        );
        address hookDeployed = factory.deploy(hookCode, hookSalt);
        require(hookDeployed == hookAddr, "hook addr mismatch");
        return TrinityHookV7(hookDeployed);
    }

    function _registerAndInit(
        TrinityHookV7 hook,
        address quoteAsset,
        int24 tickBase,
        int24[] memory bandWidths
    ) internal {
        uint256 n = bandWidths.length;
        int24[] memory lowers = new int24[](n);
        int24[] memory uppers = new int24[](n);
        int24 cursor = tickBase;
        for (uint256 i = 0; i < n; i++) {
            lowers[i] = cursor;
            cursor += bandWidths[i];
            uppers[i] = cursor;
        }

        PoolKey memory key = PoolKey(
            Currency.wrap(TRINI),
            Currency.wrap(quoteAsset),
            0, 200, IHooks(address(hook))
        );

        hook.registerPool(key, lowers, uppers, MULTISIG);

        int24 initTick = tickBase - 200;
        PM.initialize(key, TickMath.getSqrtPriceAtTick(initTick));
    }

    function _logSeedParams(
        string memory name,
        address hookAddr,
        address quoteAsset,
        int24 tickBase,
        int24[] memory bandWidths,
        uint256 triniAmount
    ) internal pure {
        int24 tl = tickBase;
        int24 tu = tickBase + bandWidths[0];
        uint128 liquidity = _computeLiquidityFromAmount0(tl, tu, triniAmount);

        console2.log("  %s:", name);
        console2.log("    Hook:      ", hookAddr);
        console2.log("    TRINI:      %d", triniAmount / 1e18);
        console2.log("    Liquidity:  %d", uint256(liquidity));
        console2.log("    Quote:      ", quoteAsset);
        console2.log("");
    }

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
}
