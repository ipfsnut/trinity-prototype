"use client";

import { useState } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import {
  useAccount,
  usePublicClient,
  useWalletClient,
} from "wagmi";
import { encodePacked, encodeAbiParameters, encodeFunctionData } from "viem";
import Link from "next/link";
import { ADDRESSES, POOLS, erc20Abi, type PoolId } from "@/lib/contracts";

const POSITION_MANAGER = "0x7c5f5a4bbd8fd63184577525326123b519429bdc" as `0x${string}`;

// Actions
const MINT_POSITION = 0x02;
const SETTLE_PAIR = 0x0d;
const CLOSE_CURRENCY = 0x12;

// Full range ticks for tickSpacing=1
const TICK_LOWER = -887272;
const TICK_UPPER = 887272;

// Pools were initialized at sqrtPriceX96 = 2^96 (tick 0 = 1:1 raw ratio).
// For LP, both tokens need equal RAW amounts. We seed a tiny position.
const SEED_RAW = 100000n; // 100K raw units of each token (dust)

export default function LPPage() {
  const { address, isConnected } = useAccount();
  const publicClient = usePublicClient();
  const { data: walletClient } = useWalletClient();
  const [pool, setPool] = useState<PoolId>("usdc");
  const [loading, setLoading] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState(false);

  const p = POOLS[pool];

  async function sendAndWait(to: `0x${string}`, data: `0x${string}`) {
    if (!walletClient || !publicClient) throw new Error("No wallet");
    const hash = await walletClient.sendTransaction({
      to, data, chain: walletClient.chain, account: walletClient.account,
      gas: 600_000n,
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 60_000 });
    if (receipt.status !== "success") throw new Error("Transaction reverted");
    return hash;
  }

  async function handleSeedLP() {
    if (!address) return;
    setLoading("Starting..."); setError(null); setSuccess(false);

    try {
      const { currency0, currency1 } = p.poolKey;

      // Approve both tokens to PositionManager
      setLoading("Approving " + (currency0.toLowerCase() === ADDRESSES.trini.toLowerCase() ? "TRINI" : p.quoteSymbol) + "...");
      await sendAndWait(currency0, encodeFunctionData({
        abi: erc20Abi, functionName: "approve",
        args: [POSITION_MANAGER, SEED_RAW],
      }));

      setLoading("Approving " + (currency1.toLowerCase() === ADDRESSES.trini.toLowerCase() ? "TRINI" : p.quoteSymbol) + "...");
      await sendAndWait(currency1, encodeFunctionData({
        abi: erc20Abi, functionName: "approve",
        args: [POSITION_MANAGER, SEED_RAW],
      }));

      // Encode: MINT_POSITION + SETTLE_PAIR + CLOSE_CURRENCY x2
      // MINT creates the position (PM pulls tokens via delta)
      // SETTLE_PAIR pays the deltas
      // CLOSE_CURRENCY handles any dust

      // At sqrtPrice=2^96 with full range and equal raw amounts,
      // liquidity ≈ SEED_RAW (simplified, PM will use what fits)
      const liquidity = SEED_RAW;

      const mintParams = encodeAbiParameters(
        [
          { type: "tuple", components: [
            { type: "address" }, { type: "address" },
            { type: "uint24" }, { type: "int24" }, { type: "address" },
          ]},
          { type: "int24" }, { type: "int24" },
          { type: "uint256" },
          { type: "uint128" }, { type: "uint128" },
          { type: "address" }, { type: "bytes" },
        ],
        [
          [p.poolKey.currency0, p.poolKey.currency1, p.poolKey.fee, p.poolKey.tickSpacing, p.poolKey.hooks] as const,
          TICK_LOWER, TICK_UPPER,
          liquidity,
          SEED_RAW, SEED_RAW,
          address,
          "0x",
        ]
      );

      const settlePairParams = encodeAbiParameters(
        [{ type: "address" }, { type: "address" }],
        [currency0, currency1]
      );

      const close0Params = encodeAbiParameters(
        [{ type: "address" }], [currency0]
      );
      const close1Params = encodeAbiParameters(
        [{ type: "address" }], [currency1]
      );

      const actions = encodePacked(
        ["uint8", "uint8", "uint8", "uint8"],
        [MINT_POSITION, SETTLE_PAIR, CLOSE_CURRENCY, CLOSE_CURRENCY]
      );

      const unlockData = encodeAbiParameters(
        [{ type: "bytes" }, { type: "bytes[]" }],
        [actions, [mintParams, settlePairParams, close0Params, close1Params]]
      );

      const deadline = BigInt(Math.floor(Date.now() / 1000) + 1200);

      setLoading("Adding LP seed...");
      await sendAndWait(POSITION_MANAGER, encodeFunctionData({
        abi: [{ type: "function", name: "modifyLiquidities", inputs: [
          { type: "bytes", name: "unlockData" },
          { type: "uint256", name: "deadline" },
        ], outputs: [], stateMutability: "payable" }],
        functionName: "modifyLiquidities",
        args: [unlockData, deadline],
      }));

      setSuccess(true);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Failed");
    } finally {
      setLoading(null);
    }
  }

  const triIsC0 = p.poolKey.currency0.toLowerCase() === ADDRESSES.trini.toLowerCase();
  const quoteLabel = p.quoteSymbol;
  const token0Label = triIsC0 ? "TRINI" : quoteLabel;
  const token1Label = triIsC0 ? quoteLabel : "TRINI";
  const token0Decimals = triIsC0 ? 18 : p.quoteDecimals;
  const token1Decimals = triIsC0 ? p.quoteDecimals : 18;
  const amount0Display = Number(SEED_RAW) / 10 ** token0Decimals;
  const amount1Display = Number(SEED_RAW) / 10 ** token1Decimals;

  return (
    <div className="min-h-screen flex flex-col">
      <nav className="flex items-center justify-between px-6 py-4 border-b border-[#0f3460]">
        <div className="flex items-center gap-6">
          <span className="text-xl font-bold text-white">Trinity</span>
          <div className="flex gap-4 text-sm">
            <Link href="/" className="text-[#8892a4] hover:text-white transition-colors">Trade</Link>
            <Link href="/stake" className="text-[#8892a4] hover:text-white transition-colors">Stake</Link>
            <Link href="/lp" className="text-[#4ecca3] font-medium">Add LP</Link>
            <Link href="/docs" className="text-[#8892a4] hover:text-white transition-colors">Docs</Link>
          </div>
        </div>
        <ConnectButton />
      </nav>

      <main className="flex-1 flex items-start justify-center pt-12 px-4">
        <div className="w-full max-w-md space-y-6">
          <div>
            <h1 className="text-2xl font-bold text-white">Seed LP Position</h1>
            <p className="text-sm text-[#8892a4]">
              Add a tiny LP position to make the pool visible to indexers.
              The hook handles all pricing &mdash; this LP earns no fees.
            </p>
          </div>

          {/* Pool selector */}
          <div className="flex gap-2">
            {(Object.keys(POOLS) as PoolId[]).map((id) => (
              <button
                key={id}
                onClick={() => { setPool(id); setError(null); setSuccess(false); }}
                className={`px-4 py-2 rounded-lg text-sm font-medium transition-colors ${
                  pool === id ? "text-white" : "bg-[#16213e] text-[#8892a4] hover:text-white"
                }`}
                style={pool === id ? { background: POOLS[id].color } : {}}
              >
                {POOLS[id].quoteSymbol}
              </button>
            ))}
          </div>

          <div className="bg-[#16213e] rounded-xl p-5 border border-[#0f3460] space-y-4">
            <div className="bg-[#0d1117] rounded-lg p-4 border border-[#0f3460] space-y-2">
              <div className="text-xs text-[#8892a4]">Seed amounts (dust)</div>
              <div className="flex justify-between text-sm">
                <span className="text-white font-mono">{amount0Display.toExponential(2)}</span>
                <span className="text-[#8892a4]">{token0Label}</span>
              </div>
              <div className="flex justify-between text-sm">
                <span className="text-white font-mono">{amount1Display.toExponential(2)}</span>
                <span className="text-[#8892a4]">{token1Label}</span>
              </div>
              <div className="text-xs text-[#8892a4] mt-2">
                Full range position at tick 0. Costs essentially nothing.
              </div>
            </div>

            {error && (
              <div className="text-sm text-[#e94560] bg-[#0d1117] rounded-lg p-3 border border-[#e94560]/30 break-all">
                {error}
              </div>
            )}

            {success && (
              <div className="text-sm text-[#4ecca3] bg-[#0d1117] rounded-lg p-3 border border-[#4ecca3]/30">
                LP seed position added! Pool should now be visible to indexers.
              </div>
            )}

            {!isConnected ? (
              <div className="text-center text-[#8892a4] py-2">Connect wallet</div>
            ) : (
              <button
                onClick={handleSeedLP}
                disabled={loading !== null}
                className="w-full py-3 rounded-lg bg-[#4ecca3] text-black font-medium disabled:opacity-50"
              >
                {loading || "Seed LP (3 txs)"}
              </button>
            )}
          </div>
        </div>
      </main>
    </div>
  );
}
