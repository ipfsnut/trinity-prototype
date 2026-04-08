"use client";

import { useState, useEffect, useCallback } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import {
  useAccount,
  useReadContract,
  useReadContracts,
  usePublicClient,
  useWalletClient,
} from "wagmi";
import { formatUnits, parseUnits, encodeFunctionData } from "viem";
import Link from "next/link";
import { ADDRESSES, stakingHubAbi, rewardGaugeAbi, trinityTokenAbi, erc20Abi } from "@/lib/contracts";
import { usePrices } from "@/lib/usePrices";
import { AdminPanel } from "@/components/AdminPanel";

type Step = "input" | "approved";

export default function StakePage() {
  const { address, isConnected } = useAccount();
  const publicClient = usePublicClient();
  const { data: walletClient } = useWalletClient();
  const [amount, setAmount] = useState("");
  const [action, setAction] = useState<"stake" | "withdraw">("stake");
  const [step, setStep] = useState<Step>("input");
  const [loading, setLoading] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const parsedAmount =
    amount && !isNaN(Number(amount)) ? parseUnits(amount, 18) : 0n;

  useEffect(() => { setStep("input"); setError(null); }, [amount, action]);

  // ── Hub global state ──────────────────────────────────────────
  const { data: globalData, refetch: refetchGlobal } = useReadContracts({
    contracts: [
      { address: ADDRESSES.stakingHub, abi: stakingHubAbi, functionName: "totalSupply" },
      { address: ADDRESSES.stakingHub, abi: stakingHubAbi, functionName: "rewardRate" },
      { address: ADDRESSES.stakingHub, abi: stakingHubAbi, functionName: "periodFinish" },
    ],
  });

  const totalStaked = globalData?.[0]?.result as bigint | undefined;
  const periodFinish = globalData?.[2]?.result as bigint | undefined;

  // ── User state ────────────────────────────────────────────────
  const { data: userStaked, refetch: refetchUserStaked } = useReadContract({
    address: ADDRESSES.stakingHub, abi: stakingHubAbi, functionName: "balanceOf",
    args: address ? [address] : undefined, query: { enabled: !!address },
  });
  const { data: earnedHub, refetch: refetchEarnedHub } = useReadContract({
    address: ADDRESSES.stakingHub, abi: stakingHubAbi, functionName: "earned",
    args: address ? [address] : undefined, query: { enabled: !!address },
  });
  const { data: earnedWeth, refetch: refetchEarnedWeth } = useReadContract({
    address: ADDRESSES.wethGauge, abi: rewardGaugeAbi, functionName: "earned",
    args: address ? [address] : undefined, query: { enabled: !!address },
  });
  const { data: earnedChaoslp, refetch: refetchEarnedChaoslp } = useReadContract({
    address: ADDRESSES.chaoslpGauge, abi: rewardGaugeAbi, functionName: "earned",
    args: address ? [address] : undefined, query: { enabled: !!address },
  });
  const { data: gaugeRates } = useReadContracts({
    contracts: [
      { address: ADDRESSES.chaoslpGauge, abi: rewardGaugeAbi, functionName: "rewardRate" },
      { address: ADDRESSES.chaoslpGauge, abi: rewardGaugeAbi, functionName: "periodFinish" },
      { address: ADDRESSES.wethGauge, abi: rewardGaugeAbi, functionName: "rewardRate" },
      { address: ADDRESSES.wethGauge, abi: rewardGaugeAbi, functionName: "periodFinish" },
    ],
  });
  const chaoslpRewardRate = gaugeRates?.[0]?.result as bigint | undefined;
  const chaoslpPeriodFinish = gaugeRates?.[1]?.result as bigint | undefined;
  const wethRewardRate = gaugeRates?.[2]?.result as bigint | undefined;
  const wethPeriodFinish2 = gaugeRates?.[3]?.result as bigint | undefined;
  const isChaoslpActive = chaoslpPeriodFinish !== undefined && Number(chaoslpPeriodFinish) > Date.now() / 1000;
  const isWethGaugeActive = wethPeriodFinish2 !== undefined && Number(wethPeriodFinish2) > Date.now() / 1000;

  // USD-denominated APR using live prices
  const prices = usePrices();
  const YEAR_SECS = 365 * 86400;

  function computeApr(rewardRate: bigint | undefined, rewardPriceUsd: number | null): number | null {
    if (!rewardRate || rewardRate === 0n || !totalStaked || totalStaked === 0n) return null;
    if (!prices.triniUsd || !rewardPriceUsd) return null;
    const annualRewardTokens = Number(formatUnits(rewardRate, 18)) * YEAR_SECS;
    const annualRewardUsd = annualRewardTokens * rewardPriceUsd;
    const stakedUsd = Number(formatUnits(totalStaked, 18)) * prices.triniUsd;
    if (stakedUsd === 0) return null;
    return (annualRewardUsd / stakedUsd) * 100;
  }

  const chaoslpApr = computeApr(chaoslpRewardRate, prices.chaoslpUsd);
  const wethApr = computeApr(wethRewardRate, prices.wethUsd);
  const { data: triBalance, refetch: refetchTriBal } = useReadContract({
    address: ADDRESSES.trini, abi: trinityTokenAbi, functionName: "balanceOf",
    args: address ? [address] : undefined, query: { enabled: !!address },
  });

  const refetchAll = useCallback(() => {
    refetchGlobal();
    refetchUserStaked();
    refetchEarnedHub();
    refetchEarnedWeth();
    refetchEarnedChaoslp();
    refetchTriBal();
  }, [refetchGlobal, refetchUserStaked, refetchEarnedHub, refetchEarnedWeth, refetchEarnedChaoslp, refetchTriBal]);

  // ── Send + wait helper ────────────────────────────────────────
  async function sendAndWait(to: `0x${string}`, data: `0x${string}`) {
    if (!walletClient || !publicClient) throw new Error("No wallet");
    const hash = await walletClient.sendTransaction({ to, data, chain: walletClient.chain, account: walletClient.account, gas: 300_000n });
    const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 30_000 });
    if (receipt.status !== "success") throw new Error("Transaction reverted");
    return hash;
  }

  // ── Approve ───────────────────────────────────────────────────
  async function handleApprove() {
    if (parsedAmount === 0n) return;
    setLoading("approve"); setError(null);
    try {
      const data = encodeFunctionData({
        abi: erc20Abi, functionName: "approve",
        args: [ADDRESSES.stakingHub, parsedAmount],
      });
      await sendAndWait(ADDRESSES.trini, data);
      setStep("approved");
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Approval failed");
    } finally { setLoading(null); }
  }

  // ── Stake ─────────────────────────────────────────────────────
  async function handleStake() {
    if (parsedAmount === 0n) return;
    setLoading("stake"); setError(null);
    try {
      const data = encodeFunctionData({
        abi: stakingHubAbi, functionName: "stake", args: [parsedAmount],
      });
      await sendAndWait(ADDRESSES.stakingHub, data);
      setAmount(""); setStep("input");
      setTimeout(() => refetchAll(), 2000);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Stake failed");
      setStep("input");
    } finally { setLoading(null); }
  }

  // ── Withdraw ──────────────────────────────────────────────────
  async function handleWithdraw() {
    if (parsedAmount === 0n) return;
    setLoading("withdraw"); setError(null);
    try {
      const data = encodeFunctionData({
        abi: stakingHubAbi, functionName: "withdraw", args: [parsedAmount],
      });
      await sendAndWait(ADDRESSES.stakingHub, data);
      setAmount(""); setStep("input");
      setTimeout(() => refetchAll(), 2000);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Withdraw failed");
    } finally { setLoading(null); }
  }

  // ── Claim ─────────────────────────────────────────────────────
  async function handleClaim() {
    setLoading("claim"); setError(null);
    try {
      const data = encodeFunctionData({
        abi: stakingHubAbi, functionName: "getReward",
      });
      await sendAndWait(ADDRESSES.stakingHub, data);
      setTimeout(() => refetchAll(), 2000);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Claim failed");
    } finally { setLoading(null); }
  }

  // ── Exit ──────────────────────────────────────────────────────
  async function handleExit() {
    setLoading("exit"); setError(null);
    try {
      const data = encodeFunctionData({
        abi: stakingHubAbi, functionName: "exit",
      });
      await sendAndWait(ADDRESSES.stakingHub, data);
      setAmount("");
      setTimeout(() => refetchAll(), 2000);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Exit failed");
    } finally { setLoading(null); }
  }

  const fmt = (val: bigint | undefined, dec: number, dp = 4) =>
    val !== undefined ? Number(formatUnits(val, dec)).toFixed(dp) : "—";

  const hasEarnings =
    (earnedHub !== undefined && (earnedHub as bigint) > 0n) ||
    (earnedWeth !== undefined && (earnedWeth as bigint) > 0n) ||
    (earnedChaoslp !== undefined && (earnedChaoslp as bigint) > 0n);

  return (
    <div className="min-h-screen flex flex-col">
      <nav className="flex items-center justify-between px-6 py-4 border-b border-[#0f3460]">
        <div className="flex items-center gap-6">
          <span className="text-xl font-bold text-white">Trinity</span>
          <div className="flex gap-4 text-sm">
            <Link href="/" className="text-[#8892a4] hover:text-white transition-colors">Trade</Link>
            <Link href="/stake" className="text-[#4ecca3] font-medium">Stake</Link>
            <Link href="/docs" className="text-[#8892a4] hover:text-white transition-colors">Docs</Link>
          </div>
        </div>
        <ConnectButton />
      </nav>

      <main className="flex-1 flex items-start justify-center pt-12 px-4">
        <div className="w-full max-w-md space-y-6">
          <div>
            <h1 className="text-2xl font-bold text-white">Stake TRINI</h1>
            <p className="text-sm text-[#8892a4]">
              Stake TRINI, earn WETH + $CHAOSLP from pool fees (when funded by multisig).
            </p>
          </div>

          {/* Stats */}
          <div className="grid grid-cols-2 gap-3 text-sm">
            <div className="bg-[#0d1117] rounded-lg p-3 border border-[#0f3460]">
              <div className="text-[#8892a4] text-xs">Total Staked</div>
              <div className="text-white font-mono">{fmt(totalStaked, 18, 0)} TRINI</div>
            </div>
            <div className="bg-[#0d1117] rounded-lg p-3 border border-[#0f3460]">
              <div className="text-[#8892a4] text-xs">Rewards</div>
              <div className={`font-mono ${(isChaoslpActive || isWethGaugeActive) ? "text-[#4ecca3]" : "text-[#8892a4]"}`}>
                {isChaoslpActive || isWethGaugeActive ? "Active" : "Not yet funded"}
              </div>
            </div>
            <div className="bg-[#0d1117] rounded-lg p-3 border border-[#0f3460]">
              <div className="text-[#8892a4] text-xs">Your Stake</div>
              <div className="text-white font-mono">{fmt(userStaked as bigint | undefined, 18, 2)} TRINI</div>
            </div>
            <div className="bg-[#0d1117] rounded-lg p-3 border border-[#0f3460]">
              <div className="text-[#8892a4] text-xs">Earned WETH</div>
              <div className="text-[#4e9af0] font-mono">{fmt(earnedWeth as bigint | undefined, 18, 6)}</div>
            </div>
            <div className="bg-[#0d1117] rounded-lg p-3 border border-[#0f3460] col-span-2">
              <div className="text-[#8892a4] text-xs">Earned $CHAOSLP</div>
              <div className="text-[#e94560] font-mono">{fmt(earnedChaoslp as bigint | undefined, 18, 2)}</div>
            </div>
          </div>

          {/* Reward streams */}
          <div className="bg-[#0d1117] rounded-lg p-4 border border-[#0f3460] space-y-2">
            <div className="flex justify-between text-[#8892a4] text-xs font-medium">
              <span>Rewards</span>
              <span>APR</span>
            </div>
            <div className="flex justify-between items-center">
              <span className="text-sm text-[#4e9af0]">WETH</span>
              <span className="text-sm font-mono">
                {isWethGaugeActive && wethApr !== null
                  ? <span className="text-[#4ecca3]">{wethApr.toFixed(1)}%</span>
                  : <span className="text-[#8892a4]">Awaiting funding</span>}
              </span>
            </div>
            <div className="flex justify-between items-center">
              <span className="text-sm text-[#e94560]">$CHAOSLP</span>
              <span className="text-sm font-mono">
                {isChaoslpActive && chaoslpApr !== null
                  ? <span className="text-[#4ecca3]">{chaoslpApr.toFixed(1)}%</span>
                  : <span className="text-[#8892a4]">Awaiting funding</span>}
              </span>
            </div>
          </div>

          {/* Stake/Withdraw */}
          <div className="bg-[#16213e] rounded-xl p-5 border border-[#0f3460] space-y-4">
            <div className="flex gap-2">
              <button
                onClick={() => { setAction("stake"); setAmount(""); setStep("input"); }}
                className={`flex-1 py-2 rounded-lg font-medium transition-colors ${
                  action === "stake" ? "bg-[#4ecca3] text-black" : "bg-[#0d1117] text-[#8892a4]"
                }`}
              >
                Stake
              </button>
              <button
                onClick={() => { setAction("withdraw"); setAmount(""); setStep("input"); }}
                className={`flex-1 py-2 rounded-lg font-medium transition-colors ${
                  action === "withdraw" ? "bg-[#e94560] text-white" : "bg-[#0d1117] text-[#8892a4]"
                }`}
              >
                Withdraw
              </button>
            </div>

            <div className="bg-[#0d1117] rounded-lg p-4 border border-[#0f3460]">
              <div className="flex justify-between text-xs text-[#8892a4] mb-2">
                <span>{action === "stake" ? "Amount to stake" : "Amount to withdraw"}</span>
                <span>
                  {action === "stake"
                    ? `Wallet: ${fmt(triBalance as bigint | undefined, 18, 2)} TRINI`
                    : `Staked: ${fmt(userStaked as bigint | undefined, 18, 2)} TRINI`}
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
                <span className="text-[#8892a4] font-medium">TRINI</span>
              </div>
              <div className="flex gap-1 mt-2">
                {[25, 50, 75, 100].map((pct) => {
                  const bal = action === "stake"
                    ? (triBalance as bigint | undefined)
                    : (userStaked as bigint | undefined);
                  return (
                    <button key={pct} disabled={!bal || step !== "input"}
                      onClick={() => {
                        if (!bal) return;
                        const val = pct === 100 ? bal : bal * BigInt(pct) / 100n;
                        setAmount(formatUnits(val, 18));
                      }}
                      className="flex-1 py-1 text-xs rounded bg-[#16213e] text-[#8892a4] hover:text-white disabled:opacity-30 transition-colors"
                    >{pct}%</button>
                  );
                })}
              </div>
            </div>

            {error && (
              <div className="text-sm text-[#e94560] bg-[#0d1117] rounded-lg p-3 border border-[#e94560]/30">
                {error}
              </div>
            )}

            {!isConnected ? (
              <div className="text-center text-[#8892a4] py-2">Connect wallet</div>
            ) : action === "stake" && step === "input" ? (
              <button
                onClick={handleApprove}
                disabled={loading !== null || parsedAmount === 0n}
                className="w-full py-3 rounded-lg bg-[#f0c040] text-black font-medium disabled:opacity-50"
              >
                {loading === "approve" ? "Approving..." : `Approve ${amount || "0"} TRINI`}
              </button>
            ) : action === "stake" && step === "approved" ? (
              <button
                onClick={handleStake}
                disabled={loading !== null}
                className="w-full py-3 rounded-lg bg-[#4ecca3] text-black font-medium disabled:opacity-50"
              >
                {loading === "stake" ? "Staking..." : `Stake ${amount} TRINI`}
              </button>
            ) : action === "withdraw" ? (
              <button
                onClick={handleWithdraw}
                disabled={loading !== null || parsedAmount === 0n}
                className="w-full py-3 rounded-lg bg-[#e94560] text-white font-medium disabled:opacity-50"
              >
                {loading === "withdraw" ? "Withdrawing..." : "Withdraw TRINI"}
              </button>
            ) : null}

            {/* Claim / Exit — always show when user has a stake */}
            {isConnected && userStaked !== undefined && (userStaked as bigint) > 0n && (
              <div className="flex gap-2">
                <button
                  onClick={handleClaim}
                  disabled={loading !== null || !hasEarnings}
                  className="flex-1 py-2 rounded-lg bg-[#4e9af0] text-white font-medium text-sm disabled:opacity-50"
                >
                  {loading === "claim" ? "Claiming..." : "Claim Rewards"}
                </button>
                <button
                  onClick={handleExit}
                  disabled={loading !== null}
                  className="flex-1 py-2 rounded-lg bg-[#0d1117] text-[#8892a4] border border-[#0f3460] font-medium text-sm disabled:opacity-50"
                >
                  {loading === "exit" ? "Exiting..." : "Exit All"}
                </button>
              </div>
            )}
          </div>

          <AdminPanel />
        </div>
      </main>
    </div>
  );
}
