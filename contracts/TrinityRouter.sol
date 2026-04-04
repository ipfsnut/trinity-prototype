// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @title TrinityRouter
/// @notice Thin swap router for TrinityHook pools.
///         Uses pre-settle pattern: pays PM before swap so hook can take().
///         Supports native ETH → WETH wrapping for ETH pool buys.
contract TrinityRouter {
    IPoolManager public immutable manager;
    IWETH9 public immutable WETH;

    error SlippageExceeded();
    error InsufficientETH();

    constructor(IPoolManager _manager, address _weth) {
        manager = _manager;
        WETH = IWETH9(_weth);
    }

    struct SwapCallback {
        PoolKey key;
        IPoolManager.SwapParams params;
        address sender;
        uint256 minOut;
        bool routerHoldsInput; // true when router pre-wrapped ETH→WETH
    }

    /// @notice Buy TRI with a quote asset (USDC, WETH, $CHAOSLP).
    ///         User must approve this router for quoteAmount of the quote asset.
    function buyTri(
        PoolKey calldata key,
        uint256 quoteAmount,
        uint256 minTriOut,
        address triToken
    ) external returns (uint256 triOut) {
        return _buyTri(key, quoteAmount, minTriOut, triToken, false);
    }

    /// @notice Buy TRI with native ETH. Router wraps to WETH automatically.
    function buyTriWithETH(
        PoolKey calldata key,
        uint256 minTriOut,
        address triToken
    ) external payable returns (uint256 triOut) {
        if (msg.value == 0) revert InsufficientETH();
        WETH.deposit{value: msg.value}();
        return _buyTri(key, msg.value, minTriOut, triToken, true);
    }

    function _buyTri(
        PoolKey calldata key,
        uint256 quoteAmount,
        uint256 minTriOut,
        address triToken,
        bool routerHoldsInput
    ) internal returns (uint256 triOut) {
        bool zeroForOne = triToken > Currency.unwrap(key.currency0)
            ? true
            : false;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(quoteAmount),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = abi.decode(
            manager.unlock(abi.encode(SwapCallback(key, params, msg.sender, minTriOut, routerHoldsInput))),
            (BalanceDelta)
        );

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        triOut = uint256(uint128(d0 > 0 ? d0 : d1));
    }

    /// @notice Sell TRI for a quote asset.
    ///         User must approve this router for triAmount of TRI.
    function sellTri(
        PoolKey calldata key,
        uint256 triAmount,
        uint256 minQuoteOut,
        address triToken
    ) external returns (uint256 quoteOut) {
        bool zeroForOne = triToken < Currency.unwrap(key.currency1)
            ? true
            : false;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(triAmount),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = abi.decode(
            manager.unlock(abi.encode(SwapCallback(key, params, msg.sender, minQuoteOut, false))),
            (BalanceDelta)
        );

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        quoteOut = uint256(uint128(d0 > 0 ? d0 : d1));
    }

    /// @notice Sell TRI and receive native ETH (unwraps WETH automatically).
    function sellTriForETH(
        PoolKey calldata key,
        uint256 triAmount,
        uint256 minEthOut,
        address triToken
    ) external returns (uint256 ethOut) {
        // Pull TRI from user into router — callback will transfer from router to PM
        IERC20Minimal(triToken).transferFrom(msg.sender, address(this), triAmount);

        bool zeroForOne = triToken < Currency.unwrap(key.currency1)
            ? true
            : false;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(triAmount),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        // Output goes to router (for WETH unwrapping), input from router (routerHoldsInput=true)
        BalanceDelta delta = abi.decode(
            manager.unlock(abi.encode(SwapCallback(key, params, address(this), minEthOut, true))),
            (BalanceDelta)
        );

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        ethOut = uint256(uint128(d0 > 0 ? d0 : d1));

        // Unwrap WETH → ETH and send to user
        WETH.withdraw(ethOut);
        (bool sent,) = msg.sender.call{value: ethOut}("");
        require(sent, "ETH transfer failed");
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not PM");
        SwapCallback memory cb = abi.decode(data, (SwapCallback));

        Currency inputCurrency = cb.params.zeroForOne ? cb.key.currency0 : cb.key.currency1;
        uint256 inputAmount = uint256(-cb.params.amountSpecified);

        // PRE-SETTLE: transfer input to PM before swap
        manager.sync(inputCurrency);
        if (cb.routerHoldsInput) {
            // Router already holds WETH from buyTriWithETH wrapping
            IERC20Minimal(Currency.unwrap(inputCurrency)).transfer(address(manager), inputAmount);
        } else {
            // Normal path: pull from user
            IERC20Minimal(Currency.unwrap(inputCurrency)).transferFrom(
                cb.sender, address(manager), inputAmount
            );
        }
        manager.settle();

        // Swap
        BalanceDelta delta = manager.swap(cb.key, cb.params, "");

        // Take positive deltas (output to recipient)
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();

        uint256 outAmount;
        if (d0 > 0) {
            outAmount = uint256(uint128(d0));
            manager.take(cb.key.currency0, cb.sender, outAmount);
        }
        if (d1 > 0) {
            outAmount = uint256(uint128(d1));
            manager.take(cb.key.currency1, cb.sender, outAmount);
        }

        if (outAmount < cb.minOut) revert SlippageExceeded();

        return abi.encode(delta);
    }

    receive() external payable {}
}
