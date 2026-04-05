// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TrinityToken} from "../src/trinity/TrinityToken.sol";
import {TrinityHookV5} from "../src/trinity/TrinityHookV5.sol";
import {ChaosLPHub} from "../src/ChaosLPHub.sol";
import {RewardGauge} from "../src/RewardGauge.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {HookMiner} from "./HookMiner.sol";
import {TokenMiner} from "./TokenMiner.sol";

contract HookFactory {
    function deploy(bytes memory bytecode, uint256 salt) external returns (address addr) {
        assembly { addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt) }
        require(addr != address(0), "CREATE2 failed");
    }
}

/// @notice Seeds one-sided LP into a V4 pool via PM.unlock() — no Permit2 needed.
///         Has a rescue() function so tokens can never get permanently stranded.
contract LPSeeder {
    IPoolManager public immutable pm;
    address public immutable owner;

    constructor(IPoolManager _pm, address _owner) {
        pm = _pm;
        owner = _owner;
    }

    struct SeedParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    function seed(SeedParams calldata p) external {
        pm.unlock(abi.encode(p));
    }

    /// @notice Recover any tokens left in this contract after seeding
    function rescue(address token, address to) external {
        require(msg.sender == owner, "not owner");
        uint256 bal = IERC20Minimal(token).balanceOf(address(this));
        if (bal > 0) IERC20Minimal(token).transfer(to, bal);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not PM");
        SeedParams memory p = abi.decode(data, (SeedParams));

        (BalanceDelta delta,) = pm.modifyLiquidity(
            p.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidityDelta: int256(uint256(p.liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        // Settle negative deltas (transfer tokens to PM)
        if (delta.amount0() < 0) {
            Currency c = p.key.currency0;
            uint256 amt = uint256(uint128(-delta.amount0()));
            pm.sync(c);
            IERC20Minimal(Currency.unwrap(c)).transfer(address(pm), amt);
            pm.settle();
        }
        if (delta.amount1() < 0) {
            Currency c = p.key.currency1;
            uint256 amt = uint256(uint128(-delta.amount1()));
            pm.sync(c);
            IERC20Minimal(Currency.unwrap(c)).transfer(address(pm), amt);
            pm.settle();
        }

        return "";
    }
}

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @title DeployTrinityV5
/// @notice Full deployment: token + hook + pool init + staking.
///         LP seeding done separately via SeedTrinityV4LP.s.sol (needs Permit2).
///
///   Usage:
///     forge script script/DeployTrinityV5.s.sol --tc DeployTrinityV5 \
///       --rpc-url base --broadcast --verify --slow -vvvv
contract DeployTrinityV5 is Script {
    // -- V4 infra on Base --
    IPoolManager constant PM = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

    // -- Quote assets --
    address constant USDC    = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH    = 0x4200000000000000000000000000000000000006;
    address constant CHAOSLP = 0x8454d062506a27675706148ECDd194E45e44067a;
    address constant MULTISIG = 0xb7DD467A573809218aAE30EB2c60e8AE3a9198a0;

    // -- Hook permission bits: BEFORE_SWAP(7) + BEFORE_SWAP_RETURNS_DELTA(3) + AFTER_SWAP(6) --
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    // -- Band config (tickSpacing=200) --
    // USDC pool: TRI(18)/USDC(6). $0.0001 base -> $0.0166 terminal. 15 bands.
    int24 constant USDC_TICK_BASE = -368400;
    int24 constant USDC_BAND_WIDTH = 3400;
    uint256 constant USDC_NUM_BANDS = 15;

    // WETH pool: TRI(18)/WETH(18). Same price range in ETH terms.
    // $0.0001 at $2055/ETH = 4.867e-8 WETH/TRI. tick = log(4.867e-8)/log(1.0001) = -168,379
    int24 constant WETH_TICK_BASE = -168400;
    int24 constant WETH_BAND_WIDTH = 3400;
    uint256 constant WETH_NUM_BANDS = 15;

    // CLP pool: TRI(18)/CLP(18). $0.0001 at CLP=$2.56e-8 = 3906 CLP/TRI.
    // tick = log(3906)/log(1.0001) = 82,717
    int24 constant CLP_TICK_BASE = 82600;
    int24 constant CLP_BAND_WIDTH = 3400;
    uint256 constant CLP_NUM_BANDS = 12;

    // Treasury
    uint256 constant TREASURY = 100_000_000 * 1e18;

    // LP allocation per pool (equal split of 900M LP tokens across 3 pools)
    uint256 constant TRIN_PER_POOL = 300_000_000 * 1e18;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("");
        console2.log("  Trinity V5 Deployment");
        console2.log("  Deployer: ", deployer);

        vm.startBroadcast(pk);

        // ---- Phase 1: CREATE2 factory (shared for token + hook) ----
        HookFactory factory = new HookFactory();

        // ---- Phase 2: Token via CREATE2 (must be below WETH = 0x4200...0006) ----
        // Mine a salt that produces a TRIN address below all quote assets,
        // ensuring TRIN is always currency0 in V4 pool keys.
        bytes memory tokenCode = abi.encodePacked(
            type(TrinityToken).creationCode,
            abi.encode(deployer)
        );
        (uint256 tokenSalt, address tokenAddr) = TokenMiner.find(
            address(factory), WETH, keccak256(tokenCode)
        );
        address tokenDeployed = factory.deploy(tokenCode, tokenSalt);
        require(tokenDeployed == tokenAddr, "token addr mismatch");
        TrinityToken tri = TrinityToken(tokenDeployed);
        console2.log("  TRIN:", address(tri));
        require(address(tri) < WETH, "TRIN must be below WETH for currency0 ordering");

        // ---- Phase 3: Hook via CREATE2 (permission bits in address) ----
        bytes memory hookCode = abi.encodePacked(
            type(TrinityHookV5).creationCode,
            abi.encode(address(PM), address(tri), deployer)
        );
        (uint256 hookSalt, address hookAddr) = HookMiner.find(
            address(factory), HOOK_FLAGS, keccak256(hookCode)
        );
        address hookDeployed = factory.deploy(hookCode, hookSalt);
        require(hookDeployed == hookAddr, "hook addr mismatch");
        TrinityHookV5 hook = TrinityHookV5(hookDeployed);
        console2.log("  Hook: ", hookAddr);

        // ---- Phase 4: Register bands + init pools ----
        _registerAndInit(tri, hook, USDC, USDC_TICK_BASE, USDC_BAND_WIDTH, USDC_NUM_BANDS, "USDC");
        _registerAndInit(tri, hook, WETH, WETH_TICK_BASE, WETH_BAND_WIDTH, WETH_NUM_BANDS, "WETH");
        _registerAndInit(tri, hook, CHAOSLP, CLP_TICK_BASE, CLP_BAND_WIDTH, CLP_NUM_BANDS, "CLP");

        // ---- Phase 5: Seed LP via LPSeeder (all in one script, no gap) ----
        LPSeeder seeder = new LPSeeder(PM, deployer);
        console2.log("  Seeder: ", address(seeder));

        // Transfer TRI to seeder for LP provision
        uint256 triForLP = tri.balanceOf(deployer) - TREASURY;
        tri.transfer(address(seeder), triForLP);

        // Seed each pool — compute L from target TRI amount per pool
        _seedPool(seeder, address(tri), USDC, address(hook), USDC_TICK_BASE, USDC_BAND_WIDTH, "USDC");
        _seedPool(seeder, address(tri), WETH, address(hook), WETH_TICK_BASE, WETH_BAND_WIDTH, "WETH");
        _seedPool(seeder, address(tri), CHAOSLP, address(hook), CLP_TICK_BASE, CLP_BAND_WIDTH, "CLP");

        // Rescue any leftover TRIN from seeder back to deployer
        seeder.rescue(address(tri), deployer);
        console2.log("  LP seeded in all 3 pools");

        // ---- Phase 6: Treasury (100M reserved + any rescued leftovers) ----
        uint256 remaining = tri.balanceOf(deployer);
        tri.transfer(MULTISIG, remaining);
        console2.log("  Treasury: %d TRIN -> multisig", remaining / 1e18);

        // ---- Phase 7: Staking ----
        ChaosLPHub hub = new ChaosLPHub(address(tri), address(tri), deployer);
        RewardGauge wethGauge = new RewardGauge(address(hub), WETH, deployer);
        hub.addExtraReward(address(wethGauge));
        hub.transferOwnership(MULTISIG);
        wethGauge.transferOwnership(MULTISIG);
        console2.log("  Hub: ", address(hub));
        console2.log("  WETH Gauge: ", address(wethGauge));

        // ---- Phase 8: Transfer hook ownership ----
        hook.transferOwnership(MULTISIG);

        vm.stopBroadcast();

        console2.log("");
        console2.log("  DEPLOYMENT COMPLETE. All pools initialized + seeded.");
        console2.log("  No separate LP seeding needed.");
        console2.log("");
    }

    /// @dev Compute liquidity L from a target amount of currency0 (TRI) for a
    ///      one-sided position below the range (currentTick < tickLower).
    ///
    ///      amount0 = L * (sqrtUpper - sqrtLower) / (sqrtLower * sqrtUpper)
    ///      => L = amount0 * sqrtLower * sqrtUpper / (sqrtUpper - sqrtLower)
    ///
    ///      All sqrtPrices are Q64.96 fixed-point, so we scale accordingly.
    function _computeLiquidityFromAmount0(
        int24 tickLower,
        int24 tickUpper,
        uint256 targetAmount0
    ) internal pure returns (uint128) {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        // L = amount0 * sqrtLower * sqrtUpper / (sqrtUpper - sqrtLower) / 2^96
        // To avoid overflow: compute in steps
        uint256 diff = uint256(sqrtUpper) - uint256(sqrtLower);
        // numerator = amount0 * sqrtLower (fits if amount0 < 2^96 and sqrtLower < 2^160)
        // We need to be careful with overflow. Use mulDiv pattern:
        // L = amount0 * sqrtLower / diff * sqrtUpper / 2^96
        // But simpler: L = amount0 * sqrtLower * sqrtUpper / diff / 2^96
        uint256 num = targetAmount0 * uint256(sqrtLower);
        uint256 L = (num / diff) * uint256(sqrtUpper) >> 96;

        require(L > 0 && L <= type(uint128).max, "L overflow or zero");
        return uint128(L);
    }

    function _seedPool(
        LPSeeder seeder,
        address triAddr,
        address quote,
        address hookAddr,
        int24 tickBase,
        int24 bandWidth,
        string memory name
    ) internal {
        PoolKey memory key = _makeKey(triAddr, quote, hookAddr);

        // Compute L from target TRI per pool for the band's tick range
        // TRI is always currency0 (sorted lower) for our pools
        uint128 liquidity = _computeLiquidityFromAmount0(
            tickBase,
            tickBase + bandWidth,
            TRIN_PER_POOL
        );

        seeder.seed(LPSeeder.SeedParams({
            key: key,
            tickLower: tickBase,
            tickUpper: tickBase + bandWidth,
            liquidity: liquidity
        }));

        console2.log("  Seeded %s pool (L=%d)", name, uint256(liquidity));
    }

    function _registerAndInit(
        TrinityToken tri,
        TrinityHookV5 hook,
        address quote,
        int24 tickBase,
        int24 bandWidth,
        uint256 numBands,
        string memory name
    ) internal {
        // Build band arrays
        int24[] memory lowers = new int24[](numBands);
        int24[] memory uppers = new int24[](numBands);
        for (uint256 i = 0; i < numBands; i++) {
            lowers[i] = tickBase + int24(int256(i)) * bandWidth;
            uppers[i] = tickBase + int24(int256(i + 1)) * bandWidth;
        }

        // Build pool key (sort currencies)
        PoolKey memory key = _makeKey(address(tri), quote, address(hook));

        // Register bands on hook
        hook.registerPool(key, lowers, uppers, MULTISIG);

        // Initialize pool one tickSpacing below band 0 (one-sided LP)
        int24 initTick = tickBase - 200;
        PM.initialize(key, TickMath.getSqrtPriceAtTick(initTick));

        console2.log("  Pool %s initialized, %d bands", name, numBands);
    }

    function _makeKey(address t, address q, address h) internal pure returns (PoolKey memory) {
        (address c0, address c1) = t < q ? (t, q) : (q, t);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, 200, IHooks(h));
    }
}
