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
} from "viem";
import {
  POOLS,
  ADDRESSES,
  erc20Abi,
  trinityTokenAbi,
  isTriCurrency0,
  type PoolId,
} from "@/lib/contracts";

// ── ABIs (inline, matching Clanker's v4-swap-clanker.ts exactly) ────────
const PERMIT2_ABI = [
  { name: "approve", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "token", type: "address" }, { name: "spender", type: "address" }, { name: "amount", type: "uint160" }, { name: "expiration", type: "uint48" }], outputs: [] },
  { name: "allowance", type: "function", stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }, { name: "token", type: "address" }, { name: "spender", type: "address" }],
    outputs: [{ name: "amount", type: "uint160" }, { name: "expiration", type: "uint48" }, { name: "nonce", type: "uint48" }] },
] as const;

const UNIVERSAL_ROUTER_ABI = [
  { name: "execute", type: "function", stateMutability: "payable",
    inputs: [{ name: "commands", type: "bytes" }, { name: "inputs", type: "bytes[]" }, { name: "deadline", type: "uint256" }], outputs: [] },
] as const;

const QUOTER_ABI = [{
  name: "quoteExactInputSingle", type: "function", stateMutability: "nonpayable",
  inputs: [{ type: "tuple", name: "params", components: [
    { name: "poolKey", type: "tuple", components: [
      { name: "currency0", type: "address" }, { name: "currency1", type: "address" },
      { name: "fee", type: "uint24" }, { name: "tickSpacing", type: "int24" }, { name: "hooks", type: "address" },
    ]},
    { name: "zeroForOne", type: "bool" }, { name: "exactAmount", type: "uint128" }, { name: "hookData", type: "bytes" },
  ]}],
  outputs: [{ name: "amountOut", type: "uint256" }, { name: "gasEstimate", type: "uint256" }],
}] as const;

type Step = "input" | "approved";

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
  const [slippageBps, setSlippageBps] = useState(200); // 2% default
  const [quoteOut, setQuoteOut] = useState<bigint | null>(null);

  const p = POOLS[pool];
  const spendToken = side === "buy" ? p.quoteAsset : ADDRESSES.trini;
  const spendDecimals = side === "buy" ? p.quoteDecimals : 18;
  const spendSymbol = side === "buy" ? p.quoteSymbol : "TRINI";
  const outDecimals = side === "buy" ? 18 : p.quoteDecimals;
  const outSymbol = side === "buy" ? "TRINI" : p.quoteSymbol;

  const parsedAmount = amount && !isNaN(Number(amount))
    ? parseUnits(amount, spendDecimals) : 0n;

  useEffect(() => { setStep("input"); setError(null); }, [amount, pool, side]);

  // ── Balances ──────────────────────────────────────────────────
  const { data: spendBalance, refetch: refetchSpend } = useReadContract({
    address: spendToken, abi: erc20Abi, functionName: "balanceOf",
    args: address ? [address] : undefined, query: { enabled: !!address },
  });

  const { data: triBalance, refetch: refetchTri } = useReadContract({
    address: ADDRESSES.trini, abi: trinityTokenAbi, functionName: "balanceOf",
    args: address ? [address] : undefined, query: { enabled: !!address },
  });

  const { data: ethData } = useBalance({ address, query: { enabled: !!address } });

  const refetchAll = useCallback(() => {
    refetchSpend(); refetchTri();
  }, [refetchSpend, refetchTri]);

  // ── Quote preview ─────────────────────────────────────────────
  const triIs0 = isTriCurrency0(p.quoteAsset);
  const [quoteFailed, setQuoteFailed] = useState(false);

  useEffect(() => {
    setQuoteOut(null);
    setQuoteFailed(false);
    if (parsedAmount === 0n || !publicClient) return;

    const zeroForOne = side === "buy" ? !triIs0 : triIs0;

    publicClient.simulateContract({
      address: ADDRESSES.quoter,
      abi: QUOTER_ABI,
      functionName: "quoteExactInputSingle",
      args: [{
        poolKey: {
          currency0: p.poolKey.currency0,
          currency1: p.poolKey.currency1,
          fee: p.poolKey.fee,
          tickSpacing: p.poolKey.tickSpacing,
          hooks: p.poolKey.hooks,
        },
        zeroForOne,
        exactAmount: parsedAmount,
        hookData: "0x",
      }],
    }).then((result) => {
      setQuoteOut(result.result[0]);
      setQuoteFailed(false);
    }).catch(() => {
      setQuoteOut(null);
      setQuoteFailed(true);
    });
  }, [parsedAmount, pool, side, publicClient, p.poolKey, triIs0]);

  // ── Approve (ERC20 -> Permit2 -> Universal Router) ────────────
  async function handleApprove() {
    if (parsedAmount === 0n || !address || !walletClient || !publicClient) return;
    setLoading("Checking approvals..."); setError(null);

    try {
      // Native ETH buys: no approval needed
      if (pool === "eth" && side === "buy") {
        setStep("approved");
        setLoading(null);
        return;
      }

      // Step 1: Check + approve token to Permit2
      {
        const permit2Allowance = await publicClient.readContract({
          address: spendToken, abi: erc20Abi, functionName: "allowance",
          args: [address, ADDRESSES.permit2],
        });

        if ((permit2Allowance as bigint) < parsedAmount) {
          setLoading("Approving token...");
          const hash = await walletClient.writeContract({
            address: spendToken, abi: erc20Abi, functionName: "approve",
            args: [ADDRESSES.permit2, BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")],
            chain: walletClient.chain, account: walletClient.account,
          });
          await publicClient.waitForTransactionReceipt({ hash });
        }
      }

      // Step 2: Check + approve Permit2 -> Universal Router
      const [routerAllowance] = await publicClient.readContract({
        address: ADDRESSES.permit2, abi: PERMIT2_ABI, functionName: "allowance",
        args: [address, spendToken, ADDRESSES.universalRouter],
      });

      if (routerAllowance < parsedAmount) {
        setLoading("Setting Permit2 allowance...");
        const hash = await walletClient.writeContract({
          address: ADDRESSES.permit2, abi: PERMIT2_ABI, functionName: "approve",
          args: [spendToken, ADDRESSES.universalRouter,
            BigInt("0xffffffffffffffffffffffffffffffff"), // uint160 max
            Math.floor(Date.now() / 1000) + 86400 * 30], // 30 day expiry
          chain: walletClient.chain, account: walletClient.account,
        });
        await publicClient.waitForTransactionReceipt({ hash });
      }

      setStep("approved");
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Approval failed");
    } finally {
      setLoading(null);
    }
  }

  // ── Execute swap (Clanker pattern: SWAP_EXACT_IN_SINGLE + SETTLE_ALL + TAKE_ALL) ──
  async function handleTrade() {
    if (parsedAmount === 0n || !address || !walletClient || !publicClient) return;
    setLoading("Swapping..."); setError(null);

    try {
      const key = p.poolKey;
      const zeroForOne = side === "buy" ? !triIs0 : triIs0;
      const tokenIn = side === "buy" ? p.quoteAsset : ADDRESSES.trini;
      const tokenOut = side === "buy" ? ADDRESSES.trini : p.quoteAsset;

      // Get fresh quote for slippage — block swap if quote fails
      let minAmountOut: bigint;
      try {
        const result = await publicClient.simulateContract({
          address: ADDRESSES.quoter, abi: QUOTER_ABI,
          functionName: "quoteExactInputSingle",
          args: [{ poolKey: key, zeroForOne, exactAmount: parsedAmount, hookData: "0x" }],
        });
        const quoted = result.result[0];
        minAmountOut = quoted * BigInt(10000 - slippageBps) / 10000n;
      } catch {
        throw new Error("Unable to get price quote. Please try again.");
      }

      const isNativeEthBuy = pool === "eth" && side === "buy";
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 1200);

      const swapParams = encodeAbiParameters(
        [{ type: "tuple", components: [
          { type: "tuple", name: "poolKey", components: [
            { name: "currency0", type: "address" }, { name: "currency1", type: "address" },
            { name: "fee", type: "uint24" }, { name: "tickSpacing", type: "int24" },
            { name: "hooks", type: "address" },
          ]},
          { name: "zeroForOne", type: "bool" },
          { name: "amountIn", type: "uint128" },
          { name: "amountOutMinimum", type: "uint128" },
          { name: "hookData", type: "bytes" },
        ]}],
        [{ poolKey: key, zeroForOne, amountIn: parsedAmount, amountOutMinimum: minAmountOut, hookData: "0x" }]
      );

      let commands: `0x${string}`;
      let inputs: `0x${string}`[];
      let txValue: bigint;

      if (isNativeEthBuy) {
        // Native ETH buy: WRAP_ETH (0x0b) + V4_SWAP (0x10)
        // WRAP_ETH wraps msg.value to WETH, held by the router
        // V4_SWAP uses SETTLE (0x0b) with payerIsUser=false so the router
        // settles from its own WETH balance (not Permit2 pull from user)
        const ADDRESS_THIS = "0x0000000000000000000000000000000000000002" as `0x${string}`;
        const wrapInput = encodeAbiParameters(
          [{ type: "address" }, { type: "uint256" }],
          [ADDRESS_THIS, parsedAmount]
        );

        // Actions: SWAP_EXACT_IN_SINGLE(0x06) + SETTLE(0x0b) + TAKE_ALL(0x0f)
        const actions = "0x060b0f" as `0x${string}`;

        // SETTLE: (address currency, uint256 amount, bool payerIsUser)
        // payerIsUser=false — use router's WETH from WRAP_ETH
        const settleParams = encodeAbiParameters(
          [{ type: "address" }, { type: "uint256" }, { type: "bool" }],
          [tokenIn, 0n, false]
        );

        // TAKE_ALL: (address currency, uint256 minAmount)
        const takeParams = encodeAbiParameters(
          [{ type: "address" }, { type: "uint256" }],
          [tokenOut, minAmountOut]
        );

        const v4Input = encodeAbiParameters(
          [{ type: "bytes" }, { type: "bytes[]" }],
          [actions, [swapParams, settleParams, takeParams]]
        );

        commands = "0x0b10";
        inputs = [wrapInput, v4Input];
        txValue = parsedAmount;
      } else {
        // ERC20 swap: V4_SWAP only (0x10)
        // SETTLE_ALL(0x0c) pulls from user via Permit2, TAKE_ALL(0x0f) sends to user
        const actions = "0x060c0f" as `0x${string}`;

        // SETTLE_ALL: (address currency, uint256 maxAmount)
        const settleParams = encodeAbiParameters(
          [{ type: "address" }, { type: "uint256" }],
          [tokenIn, parsedAmount]
        );

        // TAKE_ALL: (address currency, uint256 minAmount)
        const takeParams = encodeAbiParameters(
          [{ type: "address" }, { type: "uint256" }],
          [tokenOut, minAmountOut]
        );

        const v4Input = encodeAbiParameters(
          [{ type: "bytes" }, { type: "bytes[]" }],
          [actions, [swapParams, settleParams, takeParams]]
        );

        commands = "0x10";
        inputs = [v4Input];
        txValue = 0n;
      }

      const hash = await walletClient.sendTransaction({
        to: ADDRESSES.universalRouter,
        data: encodeFunctionData({
          abi: UNIVERSAL_ROUTER_ABI,
          functionName: "execute",
          args: [commands, inputs, deadline],
        }),
        value: txValue,
        chain: walletClient.chain,
        account: walletClient.account,
        gas: 500_000n,
      });

      await publicClient.waitForTransactionReceipt({ hash, timeout: 60_000 });
      setAmount(""); setStep("input");
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

  // For ETH pool, show note about needing WETH
  const isEthPool = pool === "eth";

  return (
    <div className="space-y-6">
      {/* Pool selector */}
      <div className="flex gap-2">
        {(Object.keys(POOLS) as PoolId[]).map((id) => (
          <button key={id}
            onClick={() => { setPool(id); setAmount(""); setStep("input"); }}
            className={`flex-1 px-3 py-2 rounded-lg text-sm font-medium transition-colors flex flex-col items-center leading-tight ${
              pool === id ? "text-white" : "bg-[#16213e] text-[#8892a4] hover:text-white"
            }`}
            style={pool === id ? { background: POOLS[id].color } : {}}
          >
            <span>{POOLS[id].quoteSymbol}</span>
            <span className={`text-[10px] ${pool === id ? "opacity-80" : "opacity-60"}`}>
              {POOLS[id].feeLabel} fee
            </span>
          </button>
        ))}
      </div>

      {/* Pool metadata */}
      <div className="flex items-center justify-between text-xs">
        <a
          href={p.geckoUrl}
          target="_blank"
          rel="noopener noreferrer"
          className="text-[#8892a4] hover:text-[#4e9af0] transition-colors"
        >
          {p.label} on GeckoTerminal &rarr;
        </a>
        <span className="text-[#8892a4]">
          Fee: <span className="font-medium text-white">{p.feeLabel}</span> on every swap
        </span>
      </div>

      {/* Buy / Sell toggle */}
      <div className="flex gap-2">
        <button
          onClick={() => { setSide("buy"); setAmount(""); setStep("input"); }}
          className={`flex-1 py-2 rounded-lg font-medium transition-colors ${
            side === "buy" ? "bg-[#4ecca3] text-black" : "bg-[#16213e] text-[#8892a4]"
          }`}
        >Buy</button>
        <button
          onClick={() => { setSide("sell"); setAmount(""); setStep("input"); }}
          className={`flex-1 py-2 rounded-lg font-medium transition-colors ${
            side === "sell" ? "bg-[#e94560] text-white" : "bg-[#16213e] text-[#8892a4]"
          }`}
        >Sell</button>
      </div>

      {/* ETH pool note */}
      {isEthPool && side === "buy" && (
        <div className="text-xs text-[#4ecca3] bg-[#0d1117] rounded-lg p-2 border border-[#4ecca3]/30">
          Send native ETH — automatically wrapped to WETH for the swap.
        </div>
      )}

      {/* Input */}
      <div className="bg-[#0d1117] rounded-lg p-4 border border-[#0f3460]">
        <div className="flex justify-between text-xs text-[#8892a4] mb-2">
          <span>You {side === "buy" ? "pay" : "sell"}</span>
          <span>
            Balance: {isEthPool && side === "buy"
            ? `${fmt(ethData?.value, 18, 4)} ETH`
            : `${fmt(spendBalance as bigint | undefined, spendDecimals, 4)} ${spendSymbol}`}
          </span>
        </div>
        <div className="flex gap-2 items-center">
          <input type="text" inputMode="decimal" placeholder="0.0"
            value={amount} onChange={(e) => setAmount(e.target.value)}
            disabled={step !== "input"}
            className="flex-1 bg-transparent text-white text-2xl font-mono outline-none disabled:opacity-50"
          />
          <span className="text-[#8892a4] font-medium">{spendSymbol}</span>
        </div>
        <div className="flex gap-1 mt-2">
          {[25, 50, 75, 100].map((pct) => {
            const bal = isEthPool && side === "buy" ? ethData?.value : spendBalance as bigint | undefined;
            return (
              <button key={pct} disabled={!bal || step !== "input"}
                onClick={() => {
                  if (!bal) return;
                  const val = pct === 100 ? bal : bal * BigInt(pct) / 100n;
                  setAmount(formatUnits(val, spendDecimals));
                }}
                className="flex-1 py-1 text-xs rounded bg-[#16213e] text-[#8892a4] hover:text-white disabled:opacity-30 transition-colors"
              >{pct}%</button>
            );
          })}
        </div>
      </div>

      {/* Preview + fee + slippage */}
      {parsedAmount > 0n && quoteFailed && side === "sell" && pool === "usdc" && (
        <div className="bg-[#1a0a0a] rounded-lg p-4 border border-[#e94560]/40 space-y-2">
          <div className="text-sm font-medium text-[#e94560]">USDC pool sold out</div>
          <p className="text-xs text-[#e0d4d4] leading-relaxed">
            Arbers have drained the USDC reserves out of this pool. The USDC pool can&apos;t accept TRINI sells right now &mdash;
            it can only accept buys until the price corrects. Try selling on the WETH or Clanker pool instead.
          </p>
          <p className="text-xs text-[#8892a4] leading-relaxed">
            The USDC pool will absorb sells again once arb flow refills its reserves (when the WETH/TRINI implied price
            exceeds the WETH/USDC price by more than the round-trip fee threshold).
          </p>
          <div className="flex gap-2 pt-1">
            <button
              onClick={() => { setPool("eth"); setAmount(""); setStep("input"); }}
              className="flex-1 px-3 py-1.5 rounded text-xs font-medium bg-[#4e9af0] text-white hover:bg-[#4e9af0]/80 transition-colors"
            >
              Sell on WETH (1%)
            </button>
            <button
              onClick={() => { setPool("clanker"); setAmount(""); setStep("input"); }}
              className="flex-1 px-3 py-1.5 rounded text-xs font-medium bg-[#e94560] text-white hover:bg-[#e94560]/80 transition-colors"
            >
              Sell on Clanker (5%)
            </button>
          </div>
        </div>
      )}

      {parsedAmount > 0n && !(quoteFailed && side === "sell" && pool === "usdc") && (
        <div className="bg-[#16213e] rounded-lg p-4 border border-[#0f3460] space-y-3">
          {quoteOut !== null && quoteOut > 0n && (
            <div>
              <div className="text-xs text-[#8892a4] mb-1">You {side === "buy" ? "receive" : "get back"}</div>
              <div className="text-white text-xl font-mono">
                {fmt(quoteOut, outDecimals, 4)} {outSymbol}
              </div>
            </div>
          )}
          <div className="text-xs text-[#8892a4]">
            {p.feeLabel} fee {side === "buy"
              ? `(${fmt(parsedAmount * BigInt(p.feeBps) / 10000n, spendDecimals, 4)} ${spendSymbol} to multisig)`
              : `(${p.feeLabel} TRINI burned)`}
          </div>
          <div className="flex items-center gap-2 text-xs">
            <span className="text-[#8892a4]">Slippage:</span>
            {[100, 200, 500].map((bps) => (
              <button key={bps} onClick={() => setSlippageBps(bps)}
                className={`px-2 py-0.5 rounded text-xs ${
                  slippageBps === bps ? "bg-[#4e9af0] text-white" : "bg-[#0d1117] text-[#8892a4] hover:text-white"
                }`}
              >{bps / 100}%</button>
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

      {/* Action */}
      {!isConnected ? (
        <div className="text-center text-[#8892a4] py-4">Connect wallet to trade</div>
      ) : step === "input" ? (
        <button onClick={handleApprove} disabled={loading !== null || parsedAmount === 0n}
          className="w-full py-3 rounded-lg bg-[#f0c040] text-black font-medium disabled:opacity-50"
        >{loading || `Approve ${amount || "0"} ${spendSymbol}`}</button>
      ) : (
        <button onClick={handleTrade} disabled={loading !== null}
          className={`w-full py-3 rounded-lg font-medium disabled:opacity-50 ${
            side === "buy" ? "bg-[#4ecca3] text-black" : "bg-[#e94560] text-white"
          }`}
        >{loading || `${side === "buy" ? "Buy" : "Sell"} TRIN`}</button>
      )}

      {/* TRINI balance */}
      {isConnected && triBalance !== undefined && (
        <div className="text-center text-sm text-[#8892a4]">
          Your TRINI: <span className="text-white font-mono">{fmt(triBalance, 18, 2)}</span>
        </div>
      )}
    </div>
  );
}
