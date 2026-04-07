// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TrinityHookV6
/// @notice Uniswap V4 hook implementing a perpetual liquidity floor via managed LP bands.
///
///   The hook manages concentrated LP positions across price bands that approximate
///   a bonding curve. Three pools (USDC, WETH, ChaosLP) with different curve shapes
///   create a permanent arb surface. The arb generates fees. Fees reward stakers.
///
///   The curves never graduate. They are permanent infrastructure — a liquidity floor
///   that supports the token at every price level the curve covers. Once the price
///   exceeds the final band, external venues handle trading above the ceiling. When
///   price returns, the curve's LP is always there as support.
///
///   Fee model:
///     BUY:  1% of quote input → community treasury (multisig)
///     SELL: 1% of TRINI input → burned (0xdead)
///
///   Permission bits (encoded in address):
///     BEFORE_ADD_LIQUIDITY        (bit 11) — block external LP permanently
///     BEFORE_SWAP                 (bit 7)  — fee extraction
///     BEFORE_SWAP_RETURNS_DELTA   (bit 3)  — modify input for fee
///     AFTER_SWAP                  (bit 6)  — band rebalancing
contract TrinityHookV6 is IHooks, Ownable, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /* ══════════════════════════════════════════════════════════════════ */
    /*                         CONSTANTS                                 */
    /* ══════════════════════════════════════════════════════════════════ */

    uint256 private constant FEE_BPS = 100;       // 1%
    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_BAND_STEPS = 5;   // max band transitions per swap
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /* ══════════════════════════════════════════════════════════════════ */
    /*                         IMMUTABLES                                */
    /* ══════════════════════════════════════════════════════════════════ */

    IPoolManager public immutable manager;
    address public immutable trini;

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          TYPES                                    */
    /* ══════════════════════════════════════════════════════════════════ */

    struct Band {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    struct PoolConfig {
        Band[] bands;
        uint256 activeBand;
        address feeRecipient;
        bool triIsCurrency0;
        bool initialized;
        bool seeded;
    }

    enum CallbackType { SEED, WITHDRAW }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          STATE                                    */
    /* ══════════════════════════════════════════════════════════════════ */

    mapping(PoolId => PoolConfig) public pools;

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          EVENTS                                   */
    /* ══════════════════════════════════════════════════════════════════ */

    event PoolRegistered(PoolId indexed id, uint256 numBands);
    event BandSeeded(PoolId indexed id, uint256 bandIndex, uint128 liquidity);
    event BandTransition(PoolId indexed id, uint256 fromBand, uint256 toBand);
    event FeeCollected(PoolId indexed id, bool isBuy, uint256 feeAmount);
    event EmergencyWithdraw(PoolId indexed id, uint256 bandIndex);
    event FeeRecipientUpdated(PoolId indexed id, address newRecipient);

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          ERRORS                                   */
    /* ══════════════════════════════════════════════════════════════════ */

    error OnlyPoolManager();
    error AlreadyRegistered();
    error NotRegistered();
    error ExactOutputNotSupported();
    error OnlyHookCanAddLiquidity();
    error HookNotImplemented();
    error InvalidBandConfig();
    error NotPoolManager();

    /* ══════════════════════════════════════════════════════════════════ */
    /*                        CONSTRUCTOR                                */
    /* ══════════════════════════════════════════════════════════════════ */

    constructor(
        IPoolManager _manager,
        address _tri,
        address _owner
    ) Ownable(_owner) {
        manager = _manager;
        trini = _tri;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(manager)) revert OnlyPoolManager();
        _;
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                      OWNER FUNCTIONS                              */
    /* ══════════════════════════════════════════════════════════════════ */

    /// @notice Register a pool with its band configuration.
    ///         Call BEFORE pool initialization. Bands must be contiguous and ascending.
    function registerPool(
        PoolKey calldata key,
        int24[] calldata tickLowers,
        int24[] calldata tickUppers,
        address feeRecipient
    ) external onlyOwner {
        PoolId id = key.toId();
        PoolConfig storage config = pools[id];
        if (config.initialized) revert AlreadyRegistered();

        if (tickLowers.length != tickUppers.length) revert InvalidBandConfig();
        if (tickLowers.length == 0) revert InvalidBandConfig();
        if (feeRecipient == address(0)) revert InvalidBandConfig();

        config.feeRecipient = feeRecipient;
        config.triIsCurrency0 = Currency.unwrap(key.currency0) == trini;
        config.activeBand = 0;
        config.initialized = true;

        for (uint256 i = 0; i < tickLowers.length; i++) {
            if (tickLowers[i] >= tickUppers[i]) revert InvalidBandConfig();
            if (tickLowers[i] % key.tickSpacing != 0) revert InvalidBandConfig();
            if (tickUppers[i] % key.tickSpacing != 0) revert InvalidBandConfig();
            if (i > 0) {
                if (tickLowers[i] != tickUppers[i - 1]) revert InvalidBandConfig();
            }
            config.bands.push(Band({
                tickLower: tickLowers[i],
                tickUpper: tickUppers[i],
                liquidity: 0
            }));
        }

        emit PoolRegistered(id, tickLowers.length);
    }

    /// @notice Seed LP into a specific band. Hook calls PM.unlock() so it
    ///         becomes the position owner. Transfer TRINI to hook before calling.
    function ownerSeedBand(
        PoolKey calldata key,
        uint256 bandIndex,
        uint128 liquidity
    ) external onlyOwner nonReentrant {
        PoolId id = key.toId();
        PoolConfig storage config = pools[id];
        if (!config.initialized) revert NotRegistered();

        manager.unlock(abi.encode(
            CallbackType.SEED,
            abi.encode(key, bandIndex, liquidity)
        ));

        config.bands[bandIndex].liquidity += liquidity;
        if (!config.seeded) config.seeded = true;

        emit BandSeeded(id, bandIndex, liquidity);
    }

    /// @notice Emergency remove LP from a band. Tokens sent to owner.
    function emergencyWithdrawLP(
        PoolKey calldata key,
        uint256 bandIndex
    ) external onlyOwner nonReentrant {
        PoolId id = key.toId();
        PoolConfig storage config = pools[id];
        if (bandIndex >= config.bands.length) revert InvalidBandConfig();

        manager.unlock(abi.encode(
            CallbackType.WITHDRAW,
            abi.encode(key, bandIndex, owner())
        ));

        config.bands[bandIndex].liquidity = 0;
        emit EmergencyWithdraw(id, bandIndex);
    }

    /// @notice Emergency withdraw ERC20 tokens held by this contract.
    function withdrawTokens(
        address token,
        uint256 amount,
        address to
    ) external onlyOwner {
        _safeTransfer(token, to, amount);
    }

    /// @notice Update the fee recipient for a pool.
    function updateFeeRecipient(
        PoolKey calldata key,
        address newRecipient
    ) external onlyOwner {
        if (newRecipient == address(0)) revert InvalidBandConfig();
        PoolId id = key.toId();
        PoolConfig storage config = pools[id];
        if (!config.initialized) revert NotRegistered();
        config.feeRecipient = newRecipient;
        emit FeeRecipientUpdated(id, newRecipient);
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                      UNLOCK CALLBACK                              */
    /* ══════════════════════════════════════════════════════════════════ */

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();

        (CallbackType ctype, bytes memory payload) =
            abi.decode(data, (CallbackType, bytes));

        if (ctype == CallbackType.SEED) {
            return _handleSeed(payload);
        } else {
            return _handleWithdraw(payload);
        }
    }

    function _handleSeed(bytes memory payload) internal returns (bytes memory) {
        (PoolKey memory key, uint256 bandIndex, uint128 liquidity) =
            abi.decode(payload, (PoolKey, uint256, uint128));

        PoolConfig storage config = pools[key.toId()];
        if (bandIndex >= config.bands.length) revert InvalidBandConfig();
        Band memory band = config.bands[bandIndex];

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

        // Settle negative deltas (tokens PM consumed for LP)
        if (delta.amount0() < 0) {
            _settleTokens(key.currency0, uint256(uint128(-delta.amount0())));
        }
        if (delta.amount1() < 0) {
            _settleTokens(key.currency1, uint256(uint128(-delta.amount1())));
        }

        // Take positive deltas (accrued fees from prior position at same key).
        // Handles re-seeding after emergencyWithdrawLP.
        if (delta.amount0() > 0) {
            manager.take(key.currency0, address(this), uint256(uint128(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            manager.take(key.currency1, address(this), uint256(uint128(delta.amount1())));
        }

        return "";
    }

    function _handleWithdraw(bytes memory payload) internal returns (bytes memory) {
        (PoolKey memory key, uint256 bandIndex, address recipient) =
            abi.decode(payload, (PoolKey, uint256, address));

        PoolConfig storage config = pools[key.toId()];
        Band storage band = config.bands[bandIndex];

        if (band.liquidity == 0) return "";

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

        if (delta.amount0() > 0) {
            manager.take(key.currency0, recipient, uint256(uint128(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            manager.take(key.currency1, recipient, uint256(uint128(delta.amount1())));
        }

        return "";
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

    /// @notice Block external LP permanently. Only the hook manages liquidity.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4) {
        if (sender != address(this)) {
            revert OnlyHookCanAddLiquidity();
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Extract 1% fee before the AMM runs. Revert on exactOutput.
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId id = key.toId();
        PoolConfig storage config = pools[id];

        if (!config.initialized || !config.seeded) revert NotRegistered();

        // Always revert on exactOutput — closes the fee bypass
        if (params.amountSpecified >= 0) {
            revert ExactOutputNotSupported();
        }

        uint256 inputAmount = uint256(-params.amountSpecified);
        uint256 fee = inputAmount * FEE_BPS / BPS;
        if (fee == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        bool isBuy = params.zeroForOne != config.triIsCurrency0;

        // Take fee from PM (router pre-settled the full input)
        manager.take(inputCurrency, address(this), fee);

        if (isBuy) {
            _safeTransfer(Currency.unwrap(inputCurrency), config.feeRecipient, fee);
        } else {
            _safeTransfer(Currency.unwrap(inputCurrency), DEAD, fee);
        }

        emit FeeCollected(id, isBuy, fee);

        BeforeSwapDelta hookDelta = toBeforeSwapDelta(int128(uint128(fee)), 0);
        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    /// @notice Rebalance LP bands after price moves.
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

    /// @dev Rebalance LP bands if price crossed a boundary. Max 5 steps per swap.
    ///      When price hits the final band's ceiling, rebalancing stops — the LP
    ///      stays in the last band as a permanent liquidity floor.
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
                break;
            }
        }
    }

    /// @dev Adds LP from hook-held tokens. Note: balanceOf reads the hook's
    ///      TOTAL balance for each currency, not per-pool. When multiple pools
    ///      share TRINI as currency0, leftover TRINI from one pool's rebalance
    ///      may be swept into another pool's LP. This is accepted behavior —
    ///      it auto-redistributes TRINI across pools. Quote-side tokens are
    ///      unique per pool and never cross-contaminate.
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
        (uint160 sqrtCurrent,,,) = manager.getSlot0(key.toId());

        uint128 liquidity = _computeLiquidity(
            sqrtCurrent, sqrtLower, sqrtUpper, balance0, balance1
        );
        if (liquidity == 0) return;

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

        // Settle negative deltas (tokens PM consumed for LP)
        if (delta.amount0() < 0) {
            _settleTokens(key.currency0, uint256(uint128(-delta.amount0())));
        }
        if (delta.amount1() < 0) {
            _settleTokens(key.currency1, uint256(uint128(-delta.amount1())));
        }

        // Take positive deltas (accrued fee credits from prior position).
        // Defensive: prevents swap revert if a band is re-entered after fee accrual.
        if (delta.amount0() > 0) {
            manager.take(key.currency0, address(this), uint256(uint128(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            manager.take(key.currency1, address(this), uint256(uint128(delta.amount1())));
        }

        band.liquidity += liquidity;
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

        if (delta.amount0() > 0) {
            manager.take(key.currency0, address(this), uint256(uint128(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            manager.take(key.currency1, address(this), uint256(uint128(delta.amount1())));
        }
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                       LIQUIDITY MATH                              */
    /* ══════════════════════════════════════════════════════════════════ */

    /// @dev Compute max liquidity from available tokens for a tick range.
    ///      Uses FullMath.mulDiv for overflow-safe, full-precision math.
    ///      Divides by 2^96 first (clean Q96 denominator) to preserve precision.
    function _computeLiquidity(
        uint160 sqrtCurrent,
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128) {
        if (sqrtCurrent < sqrtLower) sqrtCurrent = sqrtLower;
        if (sqrtCurrent > sqrtUpper) sqrtCurrent = sqrtUpper;

        // L = amount0 * sqrtCurrent * sqrtUpper / (sqrtUpper - sqrtCurrent) / 2^96
        uint128 liq0 = type(uint128).max;
        if (sqrtCurrent < sqrtUpper) {
            uint256 diff = uint256(sqrtUpper) - uint256(sqrtCurrent);
            uint256 intermediate = FullMath.mulDiv(
                amount0, uint256(sqrtCurrent), 1 << 96
            );
            uint256 result = FullMath.mulDiv(
                intermediate, uint256(sqrtUpper), diff
            );
            if (result <= type(uint128).max) {
                liq0 = uint128(result);
            }
        }

        // L = amount1 * 2^96 / (sqrtCurrent - sqrtLower)
        uint128 liq1 = type(uint128).max;
        if (sqrtCurrent > sqrtLower) {
            uint256 diff = uint256(sqrtCurrent) - uint256(sqrtLower);
            uint256 result = FullMath.mulDiv(amount1, 1 << 96, diff);
            if (result <= type(uint128).max) {
                liq1 = uint128(result);
            }
        }

        return liq0 < liq1 ? liq0 : liq1;
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                       TOKEN HELPERS                               */
    /* ══════════════════════════════════════════════════════════════════ */

    function _settleTokens(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        manager.sync(currency);
        _safeTransfer(Currency.unwrap(currency), address(manager), amount);
        manager.settle();
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "transfer failed");
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                    UNIMPLEMENTED CALLBACKS                        */
    /* ══════════════════════════════════════════════════════════════════ */

    function beforeInitialize(address, PoolKey calldata, uint160)
        external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) {
        revert HookNotImplemented();
    }
}
