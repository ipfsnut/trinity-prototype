// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title TrinityHookV4
/// @notice Uniswap V4 hook that manages concentrated LP bands to approximate
///         a linear bonding curve. The AMM runs normally — this hook manages
///         WHERE liquidity sits and collects fees.
///
/// @dev Hook permissions (encoded in address):
///         BEFORE_SWAP (bit 7) — extract 1% fee from input before AMM runs
///         BEFORE_SWAP_RETURNS_DELTA (bit 3) — modify input amount for fee
///         AFTER_SWAP (bit 6) — rebalance LP bands after price moves
///
///   Fee model:
///     BUY (user sends quote → gets TRI): 1% of quote input → multisig
///     SELL (user sends TRI → gets quote): 1% of TRI input → burned (0xdead)
///
///   LP is seeded via deploy script (one-sided TRI, no quote asset needed).
///   afterInitialize is NOT used — modifyLiquidity requires unlock context.
contract TrinityHookV4 is IHooks, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /* ══════════════════════════════════════════════════════════════════ */
    /*                         CONSTANTS                                 */
    /* ══════════════════════════════════════════════════════════════════ */

    uint256 private constant FEE_BPS = 100;  // 1%
    uint256 private constant BPS = 10_000;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /* ══════════════════════════════════════════════════════════════════ */
    /*                         IMMUTABLES                                */
    /* ══════════════════════════════════════════════════════════════════ */

    IPoolManager public immutable manager;
    address public immutable tri;

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          TYPES                                    */
    /* ══════════════════════════════════════════════════════════════════ */

    struct Band {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;  // current liquidity in this band
    }

    struct PoolConfig {
        Band[] bands;
        uint256 activeBand;     // index of band containing current price
        address feeRecipient;   // where buy fees go
        bool triIsCurrency0;    // token ordering
        bool initialized;       // LP seeded
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          STATE                                    */
    /* ══════════════════════════════════════════════════════════════════ */

    mapping(PoolId => PoolConfig) public pools;

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          EVENTS                                   */
    /* ══════════════════════════════════════════════════════════════════ */

    event PoolRegistered(PoolId indexed id, uint256 numBands);
    event BandTransition(PoolId indexed id, uint256 fromBand, uint256 toBand);
    event FeeCollected(PoolId indexed id, bool isBuy, uint256 feeAmount);

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          ERRORS                                   */
    /* ══════════════════════════════════════════════════════════════════ */

    error OnlyPoolManager();
    error PoolNotRegistered();
    error AlreadyRegistered();
    error HookNotImplemented();

    /* ══════════════════════════════════════════════════════════════════ */
    /*                        CONSTRUCTOR                                */
    /* ══════════════════════════════════════════════════════════════════ */

    constructor(IPoolManager _manager, address _tri, address _owner) Ownable(_owner) {
        manager = _manager;
        tri = _tri;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(manager)) revert OnlyPoolManager();
        _;
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                      OWNER FUNCTIONS                              */
    /* ══════════════════════════════════════════════════════════════════ */

    /// @notice Register a pool with its band configuration.
    ///         Call BEFORE pool initialization. Bands define the price curve shape.
    function registerPool(
        PoolKey calldata key,
        int24[] calldata tickLowers,
        int24[] calldata tickUppers,
        address feeRecipient
    ) external onlyOwner {
        PoolId id = key.toId();
        PoolConfig storage config = pools[id];
        if (config.initialized) revert AlreadyRegistered();

        config.feeRecipient = feeRecipient;
        config.triIsCurrency0 = Currency.unwrap(key.currency0) == tri;
        config.activeBand = 0;

        for (uint256 i = 0; i < tickLowers.length; i++) {
            config.bands.push(Band({
                tickLower: tickLowers[i],
                tickUpper: tickUppers[i],
                liquidity: 0
            }));
        }

        emit PoolRegistered(id, tickLowers.length);
    }

    /// @notice Emergency withdraw ERC20 tokens from the hook
    function withdrawTokens(address token, uint256 amount, address to) external onlyOwner {
        IERC20Minimal(token).transfer(to, amount);
    }

    /// @notice Emergency remove LP from a specific band
    function withdrawLP(PoolKey calldata key, uint256 bandIndex) external onlyOwner {
        PoolId id = key.toId();
        PoolConfig storage config = pools[id];
        Band storage band = config.bands[bandIndex];

        if (band.liquidity > 0) {
            (BalanceDelta delta,) = manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: band.tickLower,
                    tickUpper: band.tickUpper,
                    liquidityDelta: -int256(uint256(band.liquidity)),
                    salt: bytes32(bandIndex)
                }),
                ""
            );
            band.liquidity = 0;

            // Settle the returned tokens to owner
            _takeTokens(key.currency0, msg.sender, delta.amount0());
            _takeTokens(key.currency1, msg.sender, delta.amount1());
        }
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                           VIEWS                                   */
    /* ══════════════════════════════════════════════════════════════════ */

    function getActiveBand(PoolId id) external view returns (uint256) {
        return pools[id].activeBand;
    }

    function getBandCount(PoolId id) external view returns (uint256) {
        return pools[id].bands.length;
    }

    function getBand(PoolId id, uint256 index) external view returns (Band memory) {
        return pools[id].bands[index];
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                      HOOK CALLBACKS                               */
    /* ══════════════════════════════════════════════════════════════════ */

    /// @notice Before swap: extract 1% fee from INPUT before the AMM runs
    ///         BUY: 1% of quote asset → multisig
    ///         SELL: 1% of TRI → burned (0xdead)
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        // Only exactInput (amountSpecified < 0)
        if (params.amountSpecified >= 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        PoolId id = key.toId();
        PoolConfig storage config = pools[id];

        uint256 inputAmount = uint256(-params.amountSpecified);
        uint256 fee = inputAmount * FEE_BPS / BPS;
        if (fee == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        // Determine input currency and whether this is buy or sell
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        bool isBuy = params.zeroForOne != config.triIsCurrency0;

        // Take fee from PM (router pre-settled the full input amount)
        manager.take(inputCurrency, address(this), fee);

        if (isBuy) {
            // Buy: fee in quote asset → multisig
            IERC20Minimal(Currency.unwrap(inputCurrency)).transfer(config.feeRecipient, fee);
        } else {
            // Sell: fee in TRI → burn
            IERC20Minimal(Currency.unwrap(inputCurrency)).transfer(DEAD, fee);
        }

        emit FeeCollected(id, isBuy, fee);

        // Return specified delta = +fee (hook consumed fee from the input)
        // This reduces amountToSwap: AMM gets (inputAmount - fee) instead of inputAmount
        // The hook's delta from take() (-fee) is offset by the return (+fee) → net 0
        BeforeSwapDelta hookDelta = toBeforeSwapDelta(int128(uint128(fee)), 0);
        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    /// @notice After swap: rebalance LP bands if price crossed a boundary
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();
        PoolConfig storage config = pools[id];

        _checkAndRebalance(key, config, id);

        return (IHooks.afterSwap.selector, 0);
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                     BAND REBALANCING                              */
    /* ══════════════════════════════════════════════════════════════════ */

    function _checkAndRebalance(
        PoolKey calldata key,
        PoolConfig storage config,
        PoolId id
    ) internal {
        (, int24 currentTick,,) = manager.getSlot0(id);

        uint256 active = config.activeBand;
        Band storage currentBand = config.bands[active];

        // Price moved above current band
        if (currentTick >= currentBand.tickUpper && active < config.bands.length - 1) {
            // Remove liquidity from current band
            _removeLiquidityFromBand(key, config, active);
            // Move to next band
            config.activeBand = active + 1;
            // Add liquidity to new band
            _addLiquidityToBand(key, config, active + 1);
            emit BandTransition(id, active, active + 1);
        }
        // Price moved below current band
        else if (currentTick < currentBand.tickLower && active > 0) {
            _removeLiquidityFromBand(key, config, active);
            config.activeBand = active - 1;
            _addLiquidityToBand(key, config, active - 1);
            emit BandTransition(id, active, active - 1);
        }
    }

    function _addLiquidityToBand(
        PoolKey calldata key,
        PoolConfig storage config,
        uint256 bandIndex
    ) internal {
        Band storage band = config.bands[bandIndex];

        // Compute how much liquidity we can add from the hook's token balances
        uint256 balance0 = IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 balance1 = IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(address(this));

        if (balance0 == 0 && balance1 == 0) return;

        // Approve tokens to PM for the modifyLiquidity call
        IERC20Minimal(Currency.unwrap(key.currency0)).approve(address(manager), balance0);
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(address(manager), balance1);

        // Compute liquidity from available balances
        // Use a conservative estimate — PM will pull what it needs up to our balance
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(band.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(band.tickUpper);
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        uint160 sqrtCurrent = TickMath.getSqrtPriceAtTick(currentTick);

        uint128 liquidity = _computeLiquidity(
            sqrtCurrent, sqrtLower, sqrtUpper, balance0, balance1
        );

        if (liquidity == 0) return;

        // Settle tokens to PM first
        _settleTokens(key.currency0, balance0);
        _settleTokens(key.currency1, balance1);

        // Add LP
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

        band.liquidity = liquidity;

        // Take back any unused tokens
        if (delta.amount0() > 0) {
            manager.take(key.currency0, address(this), uint256(uint128(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            manager.take(key.currency1, address(this), uint256(uint128(delta.amount1())));
        }
    }

    function _removeLiquidityFromBand(
        PoolKey calldata key,
        PoolConfig storage config,
        uint256 bandIndex
    ) internal {
        Band storage band = config.bands[bandIndex];
        if (band.liquidity == 0) return;

        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: band.tickLower,
                tickUpper: band.tickUpper,
                liquidityDelta: -int256(uint256(band.liquidity)),
                salt: bytes32(bandIndex)
            }),
            ""
        );

        band.liquidity = 0;

        // Take the returned tokens back to hook
        _takeTokens(key.currency0, address(this), delta.amount0());
        _takeTokens(key.currency1, address(this), delta.amount1());
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                       LIQUIDITY MATH                              */
    /* ══════════════════════════════════════════════════════════════════ */

    /// @dev Compute max liquidity from available token amounts for a range
    function _computeLiquidity(
        uint160 sqrtCurrent,
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128) {
        // Clamp current price to range
        if (sqrtCurrent < sqrtLower) sqrtCurrent = sqrtLower;
        if (sqrtCurrent > sqrtUpper) sqrtCurrent = sqrtUpper;

        // Liquidity from amount0 (above current price)
        uint128 liq0 = type(uint128).max;
        if (sqrtCurrent < sqrtUpper) {
            // L = amount0 * sqrtCurrent * sqrtUpper / (sqrtUpper - sqrtCurrent)
            uint256 num = amount0 * uint256(sqrtCurrent);
            uint256 denom = uint256(sqrtUpper) - uint256(sqrtCurrent);
            if (denom > 0) {
                liq0 = uint128(num * uint256(sqrtUpper) / denom / (1 << 96));
            }
        }

        // Liquidity from amount1 (below current price)
        uint128 liq1 = type(uint128).max;
        if (sqrtCurrent > sqrtLower) {
            // L = amount1 / (sqrtCurrent - sqrtLower)
            uint256 denom = uint256(sqrtCurrent) - uint256(sqrtLower);
            if (denom > 0) {
                liq1 = uint128(amount1 * (1 << 96) / denom);
            }
        }

        // Take the minimum — limited by whichever token we have less of
        return liq0 < liq1 ? liq0 : liq1;
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                       TOKEN HELPERS                               */
    /* ══════════════════════════════════════════════════════════════════ */

    function _settleTokens(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        manager.sync(currency);
        IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), amount);
        manager.settle();
    }

    function _takeTokens(Currency currency, address to, int128 delta) internal {
        if (delta > 0) {
            manager.take(currency, to, uint256(uint128(delta)));
        }
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                    UNIMPLEMENTED CALLBACKS                        */
    /* ══════════════════════════════════════════════════════════════════ */

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external override returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external override returns (bytes4) {
        // Allow LP additions — hook manages bands, external LP is permitted
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    // beforeSwap is implemented above — not in unimplemented section

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external override returns (bytes4) {
        revert HookNotImplemented();
    }
}
