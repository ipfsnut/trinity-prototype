// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title TrinityHook
/// @notice Uniswap V4 hook implementing linear bonding curve pricing.
///         Fully replaces AMM — the hook IS the liquidity source.
///         One hook contract serves all three Trinity pools (USDC/WETH/$CHAOSLP).
///
/// @dev Hook permissions required (encoded in contract address):
///         BEFORE_ADD_LIQUIDITY (bit 11) — blocks external LPs
///         BEFORE_SWAP (bit 7) — intercept and override pricing
///         BEFORE_SWAP_RETURNS_DELTA (bit 3) — enables custom pricing
///         Address must end in ...X888 pattern
contract TrinityHook is IHooks, Ownable {
    using PoolIdLibrary for PoolKey;

    /* ══════════════════════════════════════════════════════════════════ */
    /*                         CONSTANTS                                 */
    /* ══════════════════════════════════════════════════════════════════ */

    uint256 private constant WAD = 1e18;
    uint256 private constant FEE_BPS = 100;
    uint256 private constant BPS = 10_000;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /* ══════════════════════════════════════════════════════════════════ */
    /*                         IMMUTABLES                                */
    /* ══════════════════════════════════════════════════════════════════ */

    IPoolManager public immutable manager;
    address public immutable tri; // TRI token address

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          TYPES                                    */
    /* ══════════════════════════════════════════════════════════════════ */

    struct CurveConfig {
        uint256 basePrice;      // WAD — floor price in quote asset per TRI
        uint256 slope;          // WAD-scaled slope
        uint256 maxSupply;      // TRI wei — max tokens for this pool
        uint256 totalSold;      // TRI wei — tokens sold from this pool
        uint256 totalBurned;    // TRI wei — tokens burned from sells
        address feeRecipient;   // where buy fees go
        uint8 quoteDecimals;    // quote asset decimals (6 for USDC, 18 for WETH/$CHAOSLP)
        bool triIsCurrency0;    // true if TRI is the lower-address token in the pair
        bool active;            // pool registered and active
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          STATE                                    */
    /* ══════════════════════════════════════════════════════════════════ */

    mapping(PoolId => CurveConfig) public curves;

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          EVENTS                                   */
    /* ══════════════════════════════════════════════════════════════════ */

    event PoolRegistered(PoolId indexed id, uint256 basePrice, uint256 slope, uint256 maxSupply);
    event Buy(PoolId indexed id, address indexed buyer, uint256 quoteIn, uint256 triOut, uint256 fee);
    event Sell(PoolId indexed id, address indexed seller, uint256 triIn, uint256 quoteOut, uint256 burned);

    /* ══════════════════════════════════════════════════════════════════ */
    /*                          ERRORS                                   */
    /* ══════════════════════════════════════════════════════════════════ */

    error OnlyPoolManager();
    error PoolNotActive();
    error ExactOutputNotSupported();
    error ExceedsSupply();
    error ExceedsSold();
    error AddLiquidityBlocked();
    error HookNotImplemented();

    /* ══════════════════════════════════════════════════════════════════ */
    /*                        CONSTRUCTOR                                */
    /* ══════════════════════════════════════════════════════════════════ */

    constructor(IPoolManager _manager, address _tri, address _owner) Ownable(_owner) {
        manager = _manager;
        tri = _tri;
        // Hook address must have bits 11, 7, 3 set (0x0888).
        // Validated at deploy time by PoolManager when pool is initialized.
        // Constructor skips validation to support CREATE2 mining and test tooling.
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(manager)) revert OnlyPoolManager();
        _;
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                      OWNER FUNCTIONS                              */
    /* ══════════════════════════════════════════════════════════════════ */

    /// @notice Register a new pool with bonding curve parameters.
    ///         Call after PoolManager.initialize() and after seeding TRI to this hook.
    function registerPool(
        PoolKey calldata key,
        uint256 basePrice,
        uint256 slope,
        uint256 maxSupply,
        address feeRecipient,
        uint8 quoteDecimals
    ) external onlyOwner {
        PoolId id = key.toId();
        bool triIs0 = Currency.unwrap(key.currency0) == tri;
        curves[id] = CurveConfig({
            basePrice: basePrice,
            slope: slope,
            maxSupply: maxSupply,
            totalSold: 0,
            totalBurned: 0,
            feeRecipient: feeRecipient,
            quoteDecimals: quoteDecimals,
            triIsCurrency0: triIs0,
            active: true
        });
        emit PoolRegistered(id, basePrice, slope, maxSupply);
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                           VIEWS                                   */
    /* ══════════════════════════════════════════════════════════════════ */

    function getCurve(PoolId id) external view returns (CurveConfig memory) {
        return curves[id];
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                      HOOK CALLBACKS                               */
    /* ══════════════════════════════════════════════════════════════════ */

    /// @notice Block all external liquidity additions
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        revert AddLiquidityBlocked();
    }

    /// @notice Core pricing logic — replaces AMM with linear bonding curve
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        // Only support exactInput (amountSpecified < 0)
        if (params.amountSpecified > 0) revert ExactOutputNotSupported();

        PoolId id = key.toId();
        CurveConfig storage config = curves[id];
        if (!config.active) revert PoolNotActive();

        uint256 amount = uint256(-params.amountSpecified);

        // Determine if this is a buy or sell
        // zeroForOne=true means user sends currency0, receives currency1
        // If TRI is currency1 and zeroForOne=true → user sends quote, receives TRI → BUY
        // If TRI is currency0 and zeroForOne=false → user sends quote, receives TRI → BUY
        bool isBuy = params.zeroForOne != config.triIsCurrency0;

        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;

        int128 outputAmount;

        if (isBuy) {
            outputAmount = _executeBuy(id, config, inputCurrency, outputCurrency, amount, sender);
        } else {
            outputAmount = _executeSell(id, config, inputCurrency, outputCurrency, amount, sender);
        }

        // Return -amountSpecified to zero out AMM, and -outputAmount as unspecified delta
        BeforeSwapDelta hookDelta = toBeforeSwapDelta(
            int128(-params.amountSpecified), // hook handled all input
            -outputAmount                     // hook provides this much output
        );
        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                     BUY / SELL LOGIC                              */
    /* ══════════════════════════════════════════════════════════════════ */

    function _executeBuy(
        PoolId id,
        CurveConfig storage config,
        Currency inputCurrency,  // quote asset
        Currency outputCurrency, // TRI
        uint256 quoteAmount,
        address sender
    ) internal returns (int128) {
        // 1% fee
        uint256 fee = quoteAmount * FEE_BPS / BPS;
        uint256 netInput = quoteAmount - fee;

        // Convert to WAD for curve math
        uint256 netInputWad = _toWad(netInput, config.quoteDecimals);
        uint256 triOut = _calcTokensOut(netInputWad, config.totalSold, config.basePrice, config.slope);

        if (config.totalSold + triOut > config.maxSupply) revert ExceedsSupply();

        // Take quote from PM + send fee. Wrapped in try-catch so the V4 Quoter
        // can simulate this swap without pre-settled tokens. In real swaps the
        // router pre-settles, so take() succeeds. In Quoter sims PM has no
        // tokens, take() reverts, we catch it — the math and deltas are still
        // correct for the quote.
        try manager.take(inputCurrency, address(this), quoteAmount) {
            if (fee > 0) {
                IERC20Minimal(Currency.unwrap(inputCurrency)).transfer(config.feeRecipient, fee);
            }
        } catch {}

        // Settle TRI to PoolManager (hook sends TRI from its balance)
        _settle(outputCurrency, triOut);

        config.totalSold += triOut;

        emit Buy(id, sender, quoteAmount, triOut, fee);
        return int128(uint128(triOut));
    }

    function _executeSell(
        PoolId id,
        CurveConfig storage config,
        Currency inputCurrency,  // TRI
        Currency outputCurrency, // quote asset
        uint256 triAmount,
        address sender
    ) internal returns (int128) {
        // 1% burn
        uint256 burnAmount = triAmount * FEE_BPS / BPS;
        uint256 sellAmount = triAmount - burnAmount;

        // Guard: can't sell more to a pool than was bought from it
        if (sellAmount > config.totalSold) revert ExceedsSold();

        // Compute quote output
        uint256 quoteOutWad = _calcQuoteOut(sellAmount, config.totalSold, config.basePrice, config.slope);
        uint256 quoteOut = _fromWad(quoteOutWad, config.quoteDecimals);

        // Take TRI from PM + burn. Same try-catch pattern for Quoter compat.
        try manager.take(inputCurrency, address(this), triAmount) {
            if (burnAmount > 0) {
                IERC20Minimal(Currency.unwrap(inputCurrency)).transfer(DEAD, burnAmount);
            }
        } catch {}
        config.totalBurned += burnAmount;

        // Settle quote asset to PoolManager (hook sends from its reserves)
        _settle(outputCurrency, quoteOut);

        config.totalSold -= sellAmount;

        emit Sell(id, sender, triAmount, quoteOut, burnAmount);
        return int128(uint128(quoteOut));
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                      BONDING CURVE MATH                           */
    /* ══════════════════════════════════════════════════════════════════ */

    /// @dev Quadratic formula to find tokens out given WAD quote input.
    ///      Δs² + K·Δs - L = 0, where K and L are derived from curve params.
    function _calcTokensOut(uint256 netQuoteWad, uint256 s, uint256 basePrice, uint256 slope)
        internal
        pure
        returns (uint256)
    {
        if (netQuoteWad == 0) return 0;
        uint256 K = (2 * WAD * basePrice) / slope + 2 * s;
        uint256 L = (2 * WAD) * (WAD * netQuoteWad / slope);
        uint256 disc = K * K + 4 * L;
        uint256 sqrtDisc = Math.sqrt(disc);
        return (sqrtDisc - K) / 2;
    }

    /// @dev Integral for quote output given sell amount.
    ///      C = basePrice·Δs/WAD + slope·Δs·(2s-Δs)/(2·WAD²)
    function _calcQuoteOut(uint256 sellAmount, uint256 s, uint256 basePrice, uint256 slope)
        internal
        pure
        returns (uint256)
    {
        if (sellAmount == 0) return 0;
        uint256 sumTerms = 2 * s - sellAmount;
        uint256 baseCost = (basePrice * sellAmount) / WAD;
        uint256 slopeCost = (slope * sellAmount / WAD) * sumTerms / (2 * WAD);
        return baseCost + slopeCost;
    }

    /* ══════════════════════════════════════════════════════════════════ */
    /*                       TOKEN HELPERS                               */
    /* ══════════════════════════════════════════════════════════════════ */

    /// @dev Settle tokens to PoolManager (CurrencySettler pattern)
    function _settle(Currency currency, uint256 amount) internal {
        manager.sync(currency);
        IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), amount);
        manager.settle();
    }

    function _toWad(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        return amount * 10 ** (18 - decimals);
    }

    function _fromWad(uint256 wadAmount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return wadAmount;
        return wadAmount / 10 ** (18 - decimals);
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

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, int128) {
        revert HookNotImplemented();
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
