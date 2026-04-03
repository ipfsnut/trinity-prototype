"use client";

import { useState, useEffect, useCallback } from "react";
import {
  useAccount,
  useReadContract,
  useReadContracts,
  usePublicClient,
  useWalletClient,
} from "wagmi";
import { formatUnits, parseUnits, encodeFunctionData } from "viem";
import {
  POOLS,
  ADDRESSES,
  bondingCurveAbi,
  erc20Abi,
  trinityTokenAbi,
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

  const p = POOLS[pool];
  const spendToken = side === "buy" ? p.quoteAsset : ADDRESSES.tri;
  const spendDecimals = side === "buy" ? p.quoteDecimals : 18;
  const spendSymbol = side === "buy" ? p.quoteSymbol : "TRI";

  const parsedAmount =
    amount && !isNaN(Number(amount))
      ? parseUnits(amount, spendDecimals)
      : 0n;

  // Reset step when inputs change
  useEffect(() => { setStep("input"); setError(null); }, [amount, pool, side]);

  // ── Read curve state ──────────────────────────────────────────
  const { data: curveData, refetch: refetchCurve } = useReadContracts({
    contracts: [
      { address: p.curve, abi: bondingCurveAbi, functionName: "currentPrice" },
      { address: p.curve, abi: bondingCurveAbi, functionName: "totalSold" },
      { address: p.curve, abi: bondingCurveAbi, functionName: "totalBurned" },
      { address: p.curve, abi: bondingCurveAbi, functionName: "tokensRemaining" },
    ],
  });

  const spotPrice = curveData?.[0]?.result as bigint | undefined;
  const totalSold = curveData?.[1]?.result as bigint | undefined;
  const totalBurned = curveData?.[2]?.result as bigint | undefined;
  const remaining = curveData?.[3]?.result as bigint | undefined;

  // ── Preview output ────────────────────────────────────────────
  const { data: preview } = useReadContract({
    address: p.curve,
    abi: bondingCurveAbi,
    functionName: side === "buy" ? "quoteTokensOut" : "quoteAssetOut",
    args: parsedAmount > 0n ? [parsedAmount] : undefined,
    query: { enabled: parsedAmount > 0n },
  });

  const previewOut = preview as bigint | undefined;
  const outDecimals = side === "buy" ? 18 : p.quoteDecimals;
  const outSymbol = side === "buy" ? "TRI" : p.quoteSymbol;

  // ── User balances ─────────────────────────────────────────────
  const { data: spendBalance, refetch: refetchSpend } = useReadContract({
    address: spendToken,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  const { data: triBalance, refetch: refetchTri } = useReadContract({
    address: ADDRESSES.tri,
    abi: trinityTokenAbi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  const refetchAll = useCallback(() => {
    refetchCurve();
    refetchSpend();
    refetchTri();
  }, [refetchCurve, refetchSpend, refetchTri]);

  // ── Send + wait helper ────────────────────────────────────────
  async function sendAndWait(to: `0x${string}`, data: `0x${string}`) {
    if (!walletClient || !publicClient) throw new Error("No wallet");
    const hash = await walletClient.sendTransaction({ to, data, chain: walletClient.chain, account: walletClient.account });
    const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 30_000 });
    if (receipt.status !== "success") throw new Error("Transaction reverted");
    return hash;
  }

  // ── Approve ───────────────────────────────────────────────────
  async function handleApprove() {
    if (parsedAmount === 0n) return;
    setLoading("approve");
    setError(null);
    try {
      const data = encodeFunctionData({
        abi: erc20Abi,
        functionName: "approve",
        args: [p.curve, parsedAmount],
      });
      await sendAndWait(spendToken, data);
      setStep("approved");
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Approval failed");
    } finally {
      setLoading(null);
    }
  }

  // ── Execute trade ─────────────────────────────────────────────
  async function handleTrade() {
    if (parsedAmount === 0n) return;
    setLoading("trade");
    setError(null);
    try {
      const data = encodeFunctionData({
        abi: bondingCurveAbi,
        functionName: side === "buy" ? "buy" : "sell",
        args: [parsedAmount, 0n],
      });
      await sendAndWait(p.curve, data);
      setAmount("");
      setStep("input");
      // Delay refetch to let RPC index
      setTimeout(() => refetchAll(), 2000);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Trade failed");
      setStep("input");
    } finally {
      setLoading(null);
    }
  }

  // ── Format helpers ────────────────────────────────────────────
  const fmt = (val: bigint | undefined, dec: number, dp = 6) =>
    val !== undefined ? Number(formatUnits(val, dec)).toFixed(dp) : "—";

  const fmtSpotPrice = (val: bigint | undefined) => {
    if (val === undefined) return "—";
    const n = Number(formatUnits(val, 18));
    if (pool === "usdc") return `$${n.toFixed(8)}`;
    return `${n.toFixed(8)} ${p.quoteSymbol}`;
  };

  const pctSold =
    totalSold !== undefined
      ? ((Number(totalSold) / Number(p.supply)) * 100).toFixed(2)
      : "—";

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

      {/* Curve stats */}
      <div className="grid grid-cols-2 gap-3 text-sm">
        <div className="bg-[#0d1117] rounded-lg p-3 border border-[#0f3460]">
          <div className="text-[#8892a4] text-xs">Spot Price</div>
          <div className="text-white font-mono text-xs">{fmtSpotPrice(spotPrice)}</div>
        </div>
        <div className="bg-[#0d1117] rounded-lg p-3 border border-[#0f3460]">
          <div className="text-[#8892a4] text-xs">% Sold</div>
          <div className="text-white font-mono">{pctSold}%</div>
        </div>
        <div className="bg-[#0d1117] rounded-lg p-3 border border-[#0f3460]">
          <div className="text-[#8892a4] text-xs">Remaining</div>
          <div className="text-white font-mono">{fmt(remaining, 18, 0)} TRI</div>
        </div>
        <div className="bg-[#0d1117] rounded-lg p-3 border border-[#0f3460]">
          <div className="text-[#8892a4] text-xs">Total Burned</div>
          <div className="text-white font-mono text-[#e94560]">
            {fmt(totalBurned, 18, 0)} TRI
          </div>
        </div>
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
            Balance: {fmt(spendBalance as bigint | undefined, spendDecimals, 4)}{" "}
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

      {/* Preview output */}
      {previewOut !== undefined && parsedAmount > 0n && (
        <div className="bg-[#16213e] rounded-lg p-4 border border-[#0f3460]">
          <div className="text-xs text-[#8892a4] mb-1">
            You {side === "buy" ? "receive" : "get back"}
          </div>
          <div className="text-white text-xl font-mono">
            {fmt(previewOut, outDecimals, 4)} {outSymbol}
          </div>
          <div className="text-xs text-[#8892a4] mt-1">
            1% fee {side === "buy" ? `\u2192 ${p.quoteSymbol} to multisig` : "\u2192 TRI burned"}
          </div>
        </div>
      )}

      {/* Error display */}
      {error && (
        <div className="text-sm text-[#e94560] bg-[#0d1117] rounded-lg p-3 border border-[#e94560]/30">
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
          {loading === "approve"
            ? "Approving..."
            : `Approve ${amount || "0"} ${spendSymbol}`}
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
          {loading === "trade"
            ? "Confirming..."
            : `${side === "buy" ? "Buy" : "Sell"} TRI`}
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
