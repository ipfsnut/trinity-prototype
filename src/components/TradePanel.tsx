"use client";

import { useState, useEffect, useCallback } from "react";
import {
  useAccount,
  useBalance,
  useReadContract,
  usePublicClient,
  useWalletClient,
} from "wagmi";
import {
  formatUnits,
  parseUnits,
  encodeFunctionData,
  encodeAbiParameters,
  encodePacked,
} from "viem";
import {
  POOLS,
  ADDRESSES,
  erc20Abi,
  trinityTokenAbi,
  universalRouterAbi,
  permit2Abi,
  isTriCurrency0,
  type PoolId,
} from "@/lib/contracts";

type Step = "input" | "approved" | "executing";

export function TradePanel() {
  const { address, isConnected } = useAccount();
  const publicClient = usePublicClient();
  const { data: walletClient } = useWalletClient();
  const [pool, setPool] = useState<PoolId>("usdc");
  const [side, setSide] = useState<"buy" | "sell">("buy");
  const [amount, setAmount] = useState("");
  const [step, setStep] = useState<Step>("input");
  const [loading, setLoading] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [slippageBps, setSlippageBps] = useState(50); // 0.5% default

  const p = POOLS[pool];
  const isEthBuy = pool === "eth" && side === "buy";
  const spendToken = isEthBuy ? undefined : (side === "buy" ? p.quoteAsset : ADDRESSES.tri);
  const spendDecimals = side === "buy" ? p.quoteDecimals : 18;
  const spendSymbol = side === "buy" ? (pool === "eth" ? "ETH" : p.quoteSymbol) : "TRI";

  const parsedAmount =
    amount && !isNaN(Number(amount))
      ? parseUnits(amount, spendDecimals)
      : 0n;

  useEffect(() => { setStep("input"); setError(null); }, [amount, pool, side]);

  // ── User balances ─────────────────────────────────────────────
  const { data: nativeEthData, refetch: refetchEth } = useBalance({
    address,
    query: { enabled: !!address && isEthBuy },
  });

  const { data: spendBalance, refetch: refetchSpend } = useReadContract({
    address: spendToken as `0x${string}`,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address && !isEthBuy },
  });

  const displaySpendBalance = isEthBuy ? nativeEthData?.value : (spendBalance as bigint | undefined);

  const { data: triBalance, refetch: refetchTri } = useReadContract({
    address: ADDRESSES.tri,
    abi: trinityTokenAbi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  const refetchAll = useCallback(() => {
    refetchSpend();
    refetchTri();
    refetchEth();
  }, [refetchSpend, refetchTri, refetchEth]);

  // ── Send + wait helper ────────────────────────────────────────
  async function sendAndWait(to: `0x${string}`, data: `0x${string}`, value?: bigint) {
    if (!walletClient || !publicClient) throw new Error("No wallet");
    const hash = await walletClient.sendTransaction({
      to, data, chain: walletClient.chain, account: walletClient.account,
      value, gas: 500_000n,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 60_000 });
    if (receipt.status !== "success") throw new Error("Transaction reverted");
    return hash;
  }

  // ── Approve (ERC20 -> Permit2 -> Universal Router) ────────────
  async function handleApprove() {
    if (parsedAmount === 0n || !address) return;
    setLoading("Approving..."); setError(null);
    try {
      if (isEthBuy) {
        // No approval needed for native ETH
        setStep("approved");
        return;
      }

      const token = spendToken!;

      // Step 1: Approve token to Permit2
      const approveData = encodeFunctionData({
        abi: erc20Abi,
        functionName: "approve",
        args: [ADDRESSES.permit2, parsedAmount],
      });
      await sendAndWait(token, approveData);

      // Step 2: Grant Permit2 allowance to Universal Router
      const permit2Data = encodeFunctionData({
        abi: permit2Abi,
        functionName: "approve",
        args: [token, ADDRESSES.universalRouter, parsedAmount > 2n ** 160n - 1n ? 2n ** 160n - 1n : parsedAmount, Number(Math.floor(Date.now() / 1000) + 86400)],
      });
      await sendAndWait(ADDRESSES.permit2, permit2Data);

      setStep("approved");
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Approval failed");
    } finally {
      setLoading(null);
    }
  }

  // ── Execute swap via Universal Router ─────────────────────────
  async function handleTrade() {
    if (parsedAmount === 0n || !address || !walletClient || !publicClient) return;
    setLoading("Swapping..."); setError(null);
    try {
      const key = p.poolKey;
      const triIs0 = isTriCurrency0(p.quoteAsset);

      // Determine swap direction
      let zeroForOne: boolean;
      let tokenIn: `0x${string}`;
      let tokenOut: `0x${string}`;

      if (side === "buy") {
        tokenIn = p.quoteAsset;
        tokenOut = ADDRESSES.tri;
        zeroForOne = !triIs0;
      } else {
        tokenIn = ADDRESSES.tri;
        tokenOut = p.quoteAsset;
        zeroForOne = triIs0;
      }

      // Quote first to get expected output
      setLoading("Getting quote...");
      const quoteData = encodeFunctionData({
        abi: [{ type: "function", name: "quoteExactInputSingle",
          inputs: [{ type: "tuple", name: "params", components: [
            { type: "tuple", name: "poolKey", components: [
              { name: "currency0", type: "address" },
              { name: "currency1", type: "address" },
              { name: "fee", type: "uint24" },
              { name: "tickSpacing", type: "int24" },
              { name: "hooks", type: "address" },
            ]},
            { name: "zeroForOne", type: "bool" },
            { name: "exactAmount", type: "uint128" },
            { name: "hookData", type: "bytes" },
          ]}],
          outputs: [{ type: "uint256" }, { type: "uint256" }],
          stateMutability: "nonpayable",
        }],
        functionName: "quoteExactInputSingle",
        args: [{ poolKey: key, zeroForOne, exactAmount: parsedAmount, hookData: "0x" }],
      });

      let minAmountOut = 1n;
      try {
        const quoteResult = await publicClient!.call({
          to: ADDRESSES.quoter,
          data: quoteData,
        });
        if (quoteResult.data) {
          const decoded = BigInt("0x" + quoteResult.data.slice(2, 66));
          // Apply slippage: minOut = quoted * (10000 - slippageBps) / 10000
          minAmountOut = decoded * BigInt(10000 - slippageBps) / 10000n;
        }
      } catch {
        // Quoter failed — use 1n as fallback (no slippage protection)
        console.warn("Quoter failed, proceeding without slippage protection");
      }

      setLoading("Swapping...");

      // V4_SWAP command = 0x10
      const commands = "0x10" as `0x${string}`;

      // Actions: SWAP_EXACT_IN_SINGLE(0x06), SETTLE(0x0b), TAKE(0x0e)
      const actions = encodePacked(
        ["uint8", "uint8", "uint8"],
        [0x06, 0x0b, 0x0e]
      );

      // Param 0: ExactInputSingleParams
      const swapParam = encodeAbiParameters(
        [{
          type: "tuple",
          components: [
            { type: "tuple", name: "poolKey", components: [
              { name: "currency0", type: "address" },
              { name: "currency1", type: "address" },
              { name: "fee", type: "uint24" },
              { name: "tickSpacing", type: "int24" },
              { name: "hooks", type: "address" },
            ]},
            { name: "zeroForOne", type: "bool" },
            { name: "amountIn", type: "uint128" },
            { name: "amountOutMinimum", type: "uint128" },
            { name: "hookData", type: "bytes" },
          ],
        }],
        [{
          poolKey: {
            currency0: key.currency0,
            currency1: key.currency1,
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: key.hooks,
          },
          zeroForOne,
          amountIn: parsedAmount,
          amountOutMinimum: minAmountOut,
          hookData: "0x",
        }]
      );

      // Param 1: SETTLE - pay input currency (amount=0 = full delta, payerIsUser=true)
      const settleParam = encodeAbiParameters(
        [{ type: "address" }, { type: "uint256" }, { type: "bool" }],
        [tokenIn, 0n, true]
      );

      // Param 2: TAKE - receive output currency (amount=0 = full delta)
      const takeParam = encodeAbiParameters(
        [{ type: "address" }, { type: "address" }, { type: "uint256" }],
        [tokenOut, address, 0n]
      );

      // Wrap as abi.encode(bytes actions, bytes[] params) for V4_SWAP input
      const v4SwapInput = encodeAbiParameters(
        [{ type: "bytes" }, { type: "bytes[]" }],
        [actions, [swapParam, settleParam, takeParam]]
      );

      const deadline = BigInt(Math.floor(Date.now() / 1000) + 1200);

      const data = encodeFunctionData({
        abi: universalRouterAbi,
        functionName: "execute",
        args: [commands, [v4SwapInput], deadline],
      });

      // For ETH buys, send value
      const value = isEthBuy ? parsedAmount : undefined;

      await sendAndWait(ADDRESSES.universalRouter, data, value);

      setAmount("");
      setStep("input");
      setTimeout(() => refetchAll(), 2000);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Trade failed");
      setStep("input");
    } finally {
      setLoading(null);
    }
  }

  const fmt = (val: bigint | undefined, dec: number, dp = 4) =>
    val !== undefined ? Number(formatUnits(val, dec)).toFixed(dp) : "\u2014";

  const outSymbol = side === "buy" ? "TRI" : (pool === "eth" ? "ETH" : p.quoteSymbol);

  return (
    <div className="space-y-6">
      {/* Pool selector */}
      <div className="flex gap-2">
        {(Object.keys(POOLS) as PoolId[]).map((id) => (
          <button
            key={id}
            onClick={() => { setPool(id); setAmount(""); setStep("input"); }}
            className={`px-4 py-2 rounded-lg text-sm font-medium transition-colors ${
              pool === id
                ? "text-white"
                : "bg-[#16213e] text-[#8892a4] hover:text-white"
            }`}
            style={pool === id ? { background: POOLS[id].color } : {}}
          >
            {POOLS[id].quoteSymbol}
          </button>
        ))}
      </div>

      {/* Buy / Sell toggle */}
      <div className="flex gap-2">
        <button
          onClick={() => { setSide("buy"); setAmount(""); setStep("input"); }}
          className={`flex-1 py-2 rounded-lg font-medium transition-colors ${
            side === "buy"
              ? "bg-[#4ecca3] text-black"
              : "bg-[#16213e] text-[#8892a4]"
          }`}
        >
          Buy
        </button>
        <button
          onClick={() => { setSide("sell"); setAmount(""); setStep("input"); }}
          className={`flex-1 py-2 rounded-lg font-medium transition-colors ${
            side === "sell"
              ? "bg-[#e94560] text-white"
              : "bg-[#16213e] text-[#8892a4]"
          }`}
        >
          Sell
        </button>
      </div>

      {/* Input */}
      <div className="bg-[#0d1117] rounded-lg p-4 border border-[#0f3460]">
        <div className="flex justify-between text-xs text-[#8892a4] mb-2">
          <span>You {side === "buy" ? "pay" : "sell"}</span>
          <span>
            Balance: {fmt(displaySpendBalance, spendDecimals, 4)}{" "}
            {spendSymbol}
          </span>
        </div>
        <div className="flex gap-2 items-center">
          <input
            type="text"
            inputMode="decimal"
            placeholder="0.0"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            disabled={step !== "input"}
            className="flex-1 bg-transparent text-white text-2xl font-mono outline-none disabled:opacity-50"
          />
          <span className="text-[#8892a4] font-medium">{spendSymbol}</span>
        </div>
      </div>

      {/* Fee + slippage info */}
      {parsedAmount > 0n && (
        <div className="bg-[#16213e] rounded-lg p-3 border border-[#0f3460] space-y-2">
          <div className="text-xs text-[#8892a4]">
            1% fee {side === "buy"
              ? `(${fmt(parsedAmount / 100n, spendDecimals, 4)} ${spendSymbol} to multisig)`
              : "(1% TRI burned)"
            }
          </div>
          <div className="flex items-center gap-2 text-xs">
            <span className="text-[#8892a4]">Slippage:</span>
            {[50, 100, 200].map((bps) => (
              <button
                key={bps}
                onClick={() => setSlippageBps(bps)}
                className={`px-2 py-0.5 rounded text-xs ${
                  slippageBps === bps
                    ? "bg-[#4e9af0] text-white"
                    : "bg-[#0d1117] text-[#8892a4] hover:text-white"
                }`}
              >
                {bps / 100}%
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Error */}
      {error && (
        <div className="text-sm text-[#e94560] bg-[#0d1117] rounded-lg p-3 border border-[#e94560]/30 break-all">
          {error}
        </div>
      )}

      {/* Action buttons */}
      {!isConnected ? (
        <div className="text-center text-[#8892a4] py-4">
          Connect wallet to trade
        </div>
      ) : step === "input" ? (
        <button
          onClick={handleApprove}
          disabled={loading !== null || parsedAmount === 0n}
          className="w-full py-3 rounded-lg bg-[#f0c040] text-black font-medium disabled:opacity-50"
        >
          {loading || (isEthBuy
            ? `Trade ${amount || "0"} ETH`
            : `Approve ${amount || "0"} ${spendSymbol}`)}
        </button>
      ) : step === "approved" ? (
        <button
          onClick={handleTrade}
          disabled={loading !== null}
          className={`w-full py-3 rounded-lg font-medium disabled:opacity-50 ${
            side === "buy"
              ? "bg-[#4ecca3] text-black"
              : "bg-[#e94560] text-white"
          }`}
        >
          {loading || `${side === "buy" ? "Buy" : "Sell"} TRI`}
        </button>
      ) : null}

      {/* TRI balance */}
      {isConnected && triBalance !== undefined && (
        <div className="text-center text-sm text-[#8892a4]">
          Your TRI: <span className="text-white font-mono">{fmt(triBalance, 18, 2)}</span>
        </div>
      )}
    </div>
  );
}
