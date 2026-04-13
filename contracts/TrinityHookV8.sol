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

/// @title TrinityHookV8 — Continuous-position launcher hook
///
///   Replaces the band-based V6/V7 hooks with a SINGLE continuous concentrated
///   liquidity position spanning a configured tick range. All committed
///   reserves contribute to L at every price within the range — no band
///   transitions, no artificial shallowness, no Type-A leakage.
///
///   This is the launcher building block: each project deploys one of these
///   per pool (USDC + N quote-asset pairs). Fully parameterized — token,
///   fee rate, range, and owner are constructor arguments.
///
///   Fee model:
///     BUY:  feeBps of quote input → community treasury (feeRecipient)
///     SELL: feeBps of token input → burned (0xdead)
///
///   Permission bits encoded in address:
///     BEFORE_ADD_LIQUIDITY        (bit 11) — block external LP permanently
///     BEFORE_SWAP                 (bit 7)  — fee extraction
///     BEFORE_SWAP_RETURNS_DELTA   (bit 3)  — modify input for fee
///
///   Why no afterSwap?
///     V6/V7 used afterSwap to rebalance bands when price crossed boundaries.
///     V8 has no bands, so there's nothing to rebalance. Saves ~3000 gas per
///     swap and removes the most fragile piece of the old design.
contract TrinityHookV8 is IHooks, Ownable, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          CONSTANTS                                */
    /* ══════════════════════════════════════════════════════════════════ */

    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_FEE_BPS = 1000; // 10% cap
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /* ══════════════════════════════════════════════════════════════════ */
    /*                         IMMUTABLES                                */
    /* ══════════════════════════════════════════════════════════════════ */

    IPoolManager public immutable manager;
    address public immutable token;       // The launched ERC20
    uint256 public immutable feeBps;      // Symmetric fee, 100 = 1%

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          TYPES                                    */
    /* ══════════════════════════════════════════════════════════════════ */

    enum CallbackType { ADD, WITHDRAW }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          STATE                                    */
    /* ══════════════════════════════════════════════════════════════════ */

    int24 public tickLower;
    int24 public tickUpper;
    uint128 public liquidity;
    address public feeRecipient;
    bool public tokenIsCurrency0;
    bool public initialized;
    bool public seeded;
    PoolId public poolId;

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          EVENTS                                   */
    /* ══════════════════════════════════════════════════════════════════ */

    event PoolRegistered(PoolId indexed id, int24 tickLower, int24 tickUpper);
    event LiquidityAdded(uint128 liquidityDelta, uint128 totalLiquidity);
    event LiquidityRemoved(uint128 liquidityDelta);
    event FeeCollected(bool isBuy, uint256 feeAmount);
    event FeeRecipientUpdated(address newRecipient);

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          ERRORS                                   */
    /* ══════════════════════════════════════════════════════════════════ */

    error AlreadyRegistered();
    error NotRegistered();
    error NotSeeded();
    error ExactOutputNotSupported();
    error OnlyHookCanAddLiquidity();
    error HookNotImplemented();
    error InvalidConfig();
    error NotPoolManager();
    error WrongPool();

    /* ══════════════════════════════════════════════════════════════════ */
    /*                        CONSTRUCTOR                                */
    /* ══════════════════════════════════════════════════════════════════ */

    constructor(
        IPoolManager _manager,
        address _token,
        uint256 _feeBps,
        address _owner
    ) Ownable(_owner) {
        if (_feeBps == 0 || _feeBps > MAX_FEE_BPS) revert InvalidConfig();
        if (_token == address(0)) revert InvalidConfig();
        manager = _manager;
        token = _token;
        feeBps = _feeBps;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(manager)) revert NotPoolManager();
        _;
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                      OWNER FUNCTIONS                              */
    /* ══════════════════════════════════════════════════════════════════ */

    /// @notice Register the pool's tick range. Call BEFORE pool initialization.
    /// @dev    The pool must use the tick spacing implied by tickLower/tickUpper
    ///         being divisible by it. We don't enforce a specific spacing here.
    function registerPool(
        PoolKey calldata key,
        int24 _tickLower,
        int24 _tickUpper,
        address _feeRecipient
    ) external onlyOwner {
        if (initialized) revert AlreadyRegistered();
        if (_tickLower >= _tickUpper) revert InvalidConfig();
        if (_tickLower % key.tickSpacing != 0) revert InvalidConfig();
        if (_tickUpper % key.tickSpacing != 0) revert InvalidConfig();
        if (_feeRecipient == address(0)) revert InvalidConfig();

        poolId = key.toId();
        tickLower = _tickLower;
        tickUpper = _tickUpper;
        feeRecipient = _feeRecipient;
        tokenIsCurrency0 = Currency.unwrap(key.currency0) == token;
        initialized = true;

        emit PoolRegistered(poolId, _tickLower, _tickUpper);
    }

    /// @notice Mint additional liquidity into the position. Tokens (both
    ///         currency0 and currency1) must be transferred to this hook
    ///         contract BEFORE calling. The hook computes the maximum
    ///         liquidity that can be minted from its current balance and
    ///         calls modifyLiquidity.
    ///
    ///         Use this both for the initial seed and for adding more
    ///         liquidity later. Pass single-sided amounts at the bottom
    ///         tick for a "single-sided EPIC at launch" position, or
    ///         two-sided amounts for a mid-band position.
    function addLiquidity(PoolKey calldata key) external onlyOwner nonReentrant {
        if (!initialized) revert NotRegistered();
        _checkPool(key);

        manager.unlock(abi.encode(
            CallbackType.ADD,
            abi.encode(key)
        ));

        if (!seeded) seeded = true;
    }

    /// @notice Remove ALL liquidity from the position. Tokens go to owner.
    ///         Pool can be re-seeded later via addLiquidity().
    function emergencyWithdraw(PoolKey calldata key) external onlyOwner nonReentrant {
        if (liquidity == 0) revert NotSeeded();
        _checkPool(key);

        manager.unlock(abi.encode(
            CallbackType.WITHDRAW,
            abi.encode(key, owner())
        ));
    }

    /// @notice Sweep ERC20 tokens stuck in this contract.
    function withdrawTokens(address _token, uint256 amount, address to) external onlyOwner {
        _safeTransfer(_token, to, amount);
    }

    /// @notice Update fee recipient.
    function updateFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert InvalidConfig();
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                      UNLOCK CALLBACK                              */
    /* ══════════════════════════════════════════════════════════════════ */

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();

        (CallbackType ctype, bytes memory payload) =
            abi.decode(data, (CallbackType, bytes));

        if (ctype == CallbackType.ADD) {
            return _handleAdd(payload);
        } else {
            return _handleWithdraw(payload);
        }
    }

    function _handleAdd(bytes memory payload) internal returns (bytes memory) {
        PoolKey memory key = abi.decode(payload, (PoolKey));

        uint256 balance0 = IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 balance1 = IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(address(this));
        if (balance0 == 0 && balance1 == 0) return "";

        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        (uint160 sqrtCurrentX96,,,) = manager.getSlot0(poolId);

        uint128 liq = _computeLiquidity(
            sqrtCurrentX96, sqrtLowerX96, sqrtUpperX96, balance0, balance1
        );
        if (liq == 0) return "";

        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liq)),
                salt: bytes32(0)
            }),
            ""
        );

        // Settle: pay tokens we owe (negative deltas)
        if (delta.amount0() < 0) {
            _settleTokens(key.currency0, uint256(uint128(-delta.amount0())));
        }
        if (delta.amount1() < 0) {
            _settleTokens(key.currency1, uint256(uint128(-delta.amount1())));
        }
        // Take: collect tokens we're owed (positive deltas)
        if (delta.amount0() > 0) {
            manager.take(key.currency0, address(this), uint256(uint128(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            manager.take(key.currency1, address(this), uint256(uint128(delta.amount1())));
        }

        liquidity += liq;
        emit LiquidityAdded(liq, liquidity);
        return "";
    }

    function _handleWithdraw(bytes memory payload) internal returns (bytes memory) {
        (PoolKey memory key, address recipient) = abi.decode(payload, (PoolKey, address));

        uint128 liq = liquidity;
        if (liq == 0) return "";

        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liq)),
                salt: bytes32(0)
            }),
            ""
        );

        liquidity = 0;

        if (delta.amount0() > 0) {
            manager.take(key.currency0, recipient, uint256(uint128(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            manager.take(key.currency1, recipient, uint256(uint128(delta.amount1())));
        }

        emit LiquidityRemoved(liq);
        return "";
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                           VIEWS                                   */
    /* ══════════════════════════════════════════════════════════════════ */

    function getPosition() external view returns (int24, int24, uint128) {
        return (tickLower, tickUpper, liquidity);
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                      HOOK CALLBACKS                               */
    /* ══════════════════════════════════════════════════════════════════ */

    /// @notice Block external LP permanently. Only this hook can mint into the pool.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4) {
        if (sender != address(this)) revert OnlyHookCanAddLiquidity();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Extract feeBps from input before the AMM runs.
    ///         Reverts on exactOutput swaps (we only support exactInput).
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (!initialized || !seeded) revert NotSeeded();
        _checkPool(key);

        if (params.amountSpecified >= 0) revert ExactOutputNotSupported();

        uint256 inputAmount = uint256(-params.amountSpecified);
        uint256 fee = inputAmount * feeBps / BPS;
        if (fee == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        bool isBuy = params.zeroForOne != tokenIsCurrency0;

        manager.take(inputCurrency, address(this), fee);

        if (isBuy) {
            // Buy fee → treasury (in quote token)
            _safeTransfer(Currency.unwrap(inputCurrency), feeRecipient, fee);
        } else {
            // Sell fee → burned (in launched token)
            _safeTransfer(Currency.unwrap(inputCurrency), DEAD, fee);
        }

        emit FeeCollected(isBuy, fee);

        BeforeSwapDelta hookDelta = toBeforeSwapDelta(int128(uint128(fee)), 0);
        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                       LIQUIDITY MATH                              */
    /* ══════════════════════════════════════════════════════════════════ */

    /// @notice Compute the maximum liquidity that can be minted from the
    ///         given amounts of c0 and c1, assuming the pool is at sqrtCurrent.
    function _computeLiquidity(
        uint160 sqrtCurrentX96,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128) {
        if (sqrtCurrentX96 < sqrtLowerX96) sqrtCurrentX96 = sqrtLowerX96;
        if (sqrtCurrentX96 > sqrtUpperX96) sqrtCurrentX96 = sqrtUpperX96;

        uint128 liq0 = type(uint128).max;
        if (sqrtCurrentX96 < sqrtUpperX96) {
            uint256 diff = uint256(sqrtUpperX96) - uint256(sqrtCurrentX96);
            uint256 intermediate = FullMath.mulDiv(amount0, uint256(sqrtCurrentX96), 1 << 96);
            uint256 result = FullMath.mulDiv(intermediate, uint256(sqrtUpperX96), diff);
            if (result <= type(uint128).max) liq0 = uint128(result);
        }

        uint128 liq1 = type(uint128).max;
        if (sqrtCurrentX96 > sqrtLowerX96) {
            uint256 diff = uint256(sqrtCurrentX96) - uint256(sqrtLowerX96);
            uint256 result = FullMath.mulDiv(amount1, 1 << 96, diff);
            if (result <= type(uint128).max) liq1 = uint128(result);
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

    function _safeTransfer(address _token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = _token.call(
            abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "transfer failed");
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                    UNIMPLEMENTED CALLBACKS                        */
    /* ══════════════════════════════════════════════════════════════════ */

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterSwap(
        address, PoolKey calldata, IPoolManager.SwapParams calldata,
        BalanceDelta, bytes calldata
    ) external pure override returns (bytes4, int128) {
        // No band rebalancing — V8 has no bands. Just return.
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }
}
