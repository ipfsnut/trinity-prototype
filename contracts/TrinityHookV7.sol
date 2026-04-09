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

/// @title TrinityHookV7
/// @notice Single-pool Uniswap V4 hook for the TRINI/Clanker bonding curve.
///
///   Same core mechanics as V6 — managed LP bands approximating a bonding curve
///   with 1% asymmetric fee extraction. Simplified to a single pool per hook,
///   eliminating the cross-pool TRINI contamination issue from V6's multi-pool
///   design. Each new quote asset gets its own hook deployment.
///
///   Fee model:
///     BUY:  1% of quote input → community treasury (feeRecipient)
///     SELL: 1% of TRINI input → burned (0xdead)
///
///   Permission bits (encoded in address):
///     BEFORE_ADD_LIQUIDITY        (bit 11) — block external LP permanently
///     BEFORE_SWAP                 (bit 7)  — fee extraction
///     BEFORE_SWAP_RETURNS_DELTA   (bit 3)  — modify input for fee
///     AFTER_SWAP                  (bit 6)  — band rebalancing
contract TrinityHookV7 is IHooks, Ownable, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /* ══════════════════════════════════════════════════════════════════ */
    /*                         CONSTANTS                                 */
    /* ══════════════════════════════════════════════════════════════════ */

    uint256 private constant FEE_BPS = 500;       // 5% — burn engine, arbs only
    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_BAND_STEPS = 5;
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

    enum CallbackType { SEED, WITHDRAW }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          STATE                                    */
    /* ══════════════════════════════════════════════════════════════════ */

    Band[] public bands;
    uint256 public activeBand;
    address public feeRecipient;
    bool public triIsCurrency0;
    bool public initialized;
    bool public seeded;
    PoolId public poolId;

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          EVENTS                                   */
    /* ══════════════════════════════════════════════════════════════════ */

    event PoolRegistered(PoolId indexed id, uint256 numBands);
    event BandSeeded(uint256 bandIndex, uint128 liquidity);
    event BandTransition(uint256 fromBand, uint256 toBand);
    event FeeCollected(bool isBuy, uint256 feeAmount);
    event EmergencyWithdraw(uint256 bandIndex);
    event FeeRecipientUpdated(address newRecipient);

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          ERRORS                                   */
    /* ══════════════════════════════════════════════════════════════════ */

    error AlreadyRegistered();
    error NotRegistered();
    error ExactOutputNotSupported();
    error OnlyHookCanAddLiquidity();
    error HookNotImplemented();
    error InvalidBandConfig();
    error NotPoolManager();
    error WrongPool();

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
        if (msg.sender != address(manager)) revert NotPoolManager();
        _;
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                      OWNER FUNCTIONS                              */
    /* ══════════════════════════════════════════════════════════════════ */

    /// @notice Register the single pool with its band configuration.
    ///         Call BEFORE pool initialization. Bands must be contiguous and ascending.
    function registerPool(
        PoolKey calldata key,
        int24[] calldata tickLowers,
        int24[] calldata tickUppers,
        address _feeRecipient
    ) external onlyOwner {
        if (initialized) revert AlreadyRegistered();
        if (tickLowers.length != tickUppers.length) revert InvalidBandConfig();
        if (tickLowers.length == 0) revert InvalidBandConfig();
        if (_feeRecipient == address(0)) revert InvalidBandConfig();

        poolId = key.toId();
        feeRecipient = _feeRecipient;
        triIsCurrency0 = Currency.unwrap(key.currency0) == trini;
        activeBand = 0;
        initialized = true;

        for (uint256 i = 0; i < tickLowers.length; i++) {
            if (tickLowers[i] >= tickUppers[i]) revert InvalidBandConfig();
            if (tickLowers[i] % key.tickSpacing != 0) revert InvalidBandConfig();
            if (tickUppers[i] % key.tickSpacing != 0) revert InvalidBandConfig();
            if (i > 0) {
                if (tickLowers[i] != tickUppers[i - 1]) revert InvalidBandConfig();
            }
            bands.push(Band({
                tickLower: tickLowers[i],
                tickUpper: tickUppers[i],
                liquidity: 0
            }));
        }

        emit PoolRegistered(poolId, tickLowers.length);
    }

    /// @notice Seed LP into a specific band. Transfer TRINI to hook before calling.
    function ownerSeedBand(
        PoolKey calldata key,
        uint256 bandIndex,
        uint128 liquidity
    ) external onlyOwner nonReentrant {
        if (!initialized) revert NotRegistered();
        _checkPool(key);

        manager.unlock(abi.encode(
            CallbackType.SEED,
            abi.encode(key, bandIndex, liquidity)
        ));

        bands[bandIndex].liquidity += liquidity;
        if (!seeded) seeded = true;

        emit BandSeeded(bandIndex, liquidity);
    }

    /// @notice Emergency remove LP from a band. Tokens sent to owner.
    function emergencyWithdrawLP(
        PoolKey calldata key,
        uint256 bandIndex
    ) external onlyOwner nonReentrant {
        if (bandIndex >= bands.length) revert InvalidBandConfig();
        _checkPool(key);

        manager.unlock(abi.encode(
            CallbackType.WITHDRAW,
            abi.encode(key, bandIndex, owner())
        ));

        bands[bandIndex].liquidity = 0;
        emit EmergencyWithdraw(bandIndex);
    }

    /// @notice Emergency withdraw ERC20 tokens held by this contract.
    function withdrawTokens(
        address token,
        uint256 amount,
        address to
    ) external onlyOwner {
        _safeTransfer(token, to, amount);
    }

    /// @notice Update the fee recipient.
    function updateFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert InvalidBandConfig();
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
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

        if (bandIndex >= bands.length) revert InvalidBandConfig();
        Band memory band = bands[bandIndex];

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

        if (delta.amount0() < 0) {
            _settleTokens(key.currency0, uint256(uint128(-delta.amount0())));
        }
        if (delta.amount1() < 0) {
            _settleTokens(key.currency1, uint256(uint128(-delta.amount1())));
        }
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

        Band storage band = bands[bandIndex];
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

    function getActiveBand() external view returns (uint256) {
        return activeBand;
    }

    function getBandCount() external view returns (uint256) {
        return bands.length;
    }

    function getBand(uint256 index) external view returns (Band memory) {
        return bands[index];
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                      HOOK CALLBACKS                               */
    /* ══════════════════════════════════════════════════════════════════ */

    /// @notice Block external LP permanently.
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
        if (!initialized || !seeded) revert NotRegistered();
        _checkPool(key);

        if (params.amountSpecified >= 0) {
            revert ExactOutputNotSupported();
        }

        uint256 inputAmount = uint256(-params.amountSpecified);
        uint256 fee = inputAmount * FEE_BPS / BPS;
        if (fee == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        bool isBuy = params.zeroForOne != triIsCurrency0;

        manager.take(inputCurrency, address(this), fee);

        if (isBuy) {
            _safeTransfer(Currency.unwrap(inputCurrency), feeRecipient, fee);
        } else {
            _safeTransfer(Currency.unwrap(inputCurrency), DEAD, fee);
        }

        emit FeeCollected(isBuy, fee);

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
        // No _checkPool here — if beforeSwap passed, this is the right pool.
        // Saves ~2600 gas (cold SLOAD for poolId + keccak).
        _checkAndRebalance(key);
        return (IHooks.afterSwap.selector, 0);
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                     BAND REBALANCING                              */
    /* ══════════════════════════════════════════════════════════════════ */

    function _checkAndRebalance(PoolKey calldata key) internal {
        (, int24 currentTick,,) = manager.getSlot0(poolId);

        uint256 steps;
        while (steps < MAX_BAND_STEPS) {
            uint256 active = activeBand;
            Band storage band = bands[active];

            if (currentTick >= band.tickUpper && active < bands.length - 1) {
                _removeLiquidityFromBand(key, active);
                activeBand = active + 1;
                _addLiquidityToBand(key, active + 1);
                emit BandTransition(active, active + 1);
                steps++;
            } else if (currentTick < band.tickLower && active > 0) {
                _removeLiquidityFromBand(key, active);
                activeBand = active - 1;
                _addLiquidityToBand(key, active - 1);
                emit BandTransition(active, active - 1);
                steps++;
            } else {
                break;
            }
        }
    }

    function _addLiquidityToBand(PoolKey calldata key, uint256 bandIndex) internal {
        Band storage band = bands[bandIndex];

        uint256 balance0 = IERC20Minimal(Currency.unwrap(key.currency0))
            .balanceOf(address(this));
        uint256 balance1 = IERC20Minimal(Currency.unwrap(key.currency1))
            .balanceOf(address(this));

        if (balance0 == 0 && balance1 == 0) return;

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(band.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(band.tickUpper);
        (uint160 sqrtCurrent,,,) = manager.getSlot0(poolId);

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

        if (delta.amount0() < 0) {
            _settleTokens(key.currency0, uint256(uint128(-delta.amount0())));
        }
        if (delta.amount1() < 0) {
            _settleTokens(key.currency1, uint256(uint128(-delta.amount1())));
        }
        if (delta.amount0() > 0) {
            manager.take(key.currency0, address(this), uint256(uint128(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            manager.take(key.currency1, address(this), uint256(uint128(delta.amount1())));
        }

        band.liquidity += liquidity;
    }

    function _removeLiquidityFromBand(PoolKey calldata key, uint256 bandIndex) internal {
        Band storage band = bands[bandIndex];
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
    /*                       INTERNAL HELPERS                            */
    /* ══════════════════════════════════════════════════════════════════ */

    function _checkPool(PoolKey calldata key) internal view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }

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
