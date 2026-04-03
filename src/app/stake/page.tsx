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
  const { data: triBalance, refetch: refetchTriBal } = useReadContract({
    address: ADDRESSES.tri, abi: trinityTokenAbi, functionName: "balanceOf",
    args: address ? [address] : undefined, query: { enabled: !!address },
  });

  const refetchAll = useCallback(() => {
    refetchGlobal();
    refetchUserStaked();
    refetchEarnedHub();
    refetchEarnedWeth();
    refetchTriBal();
  }, [refetchGlobal, refetchUserStaked, refetchEarnedHub, refetchEarnedWeth, refetchTriBal]);

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
    setLoading("approve"); setError(null);
    try {
      const data = encodeFunctionData({
        abi: erc20Abi, functionName: "approve",
        args: [ADDRESSES.stakingHub, parsedAmount],
      });
      await sendAndWait(ADDRESSES.tri, data);
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

  const isActive =
    periodFinish !== undefined && Number(periodFinish) > Date.now() / 1000;

  const hasEarnings =
    (earnedHub !== undefined && (earnedHub as bigint) > 0n) ||
    (earnedWeth !== undefined && (earnedWeth as bigint) > 0n);

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
            <h1 className="text-2xl font-bold text-white">Stake TRI</h1>
            <p className="text-sm text-[#8892a4]">
              Stake TRI, earn WETH from ETH pool fees (when funded by multisig).
            </p>
          </div>

          {/* Stats */}
          <div className="grid grid-cols-2 gap-3 text-sm">
            <div className="bg-[#0d1117] rounded-lg p-3 border border-[#0f3460]">
              <div className="text-[#8892a4] text-xs">Total Staked</div>
              <div className="text-white font-mono">{fmt(totalStaked, 18, 0)} TRI</div>
            </div>
            <div className="bg-[#0d1117] rounded-lg p-3 border border-[#0f3460]">
              <div className="text-[#8892a4] text-xs">Rewards</div>
              <div className={`font-mono ${isActive ? "text-[#4ecca3]" : "text-[#8892a4]"}`}>
                {isActive ? "Active" : "Not yet funded"}
              </div>
            </div>
            <div className="bg-[#0d1117] rounded-lg p-3 border border-[#0f3460]">
              <div className="text-[#8892a4] text-xs">Your Stake</div>
              <div className="text-white font-mono">{fmt(userStaked as bigint | undefined, 18, 2)} TRI</div>
            </div>
            <div className="bg-[#0d1117] rounded-lg p-3 border border-[#0f3460]">
              <div className="text-[#8892a4] text-xs">Earned WETH</div>
              <div className="text-[#4ecca3] font-mono">{fmt(earnedWeth as bigint | undefined, 18, 6)}</div>
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
                    ? `Wallet: ${fmt(triBalance as bigint | undefined, 18, 2)} TRI`
                    : `Staked: ${fmt(userStaked as bigint | undefined, 18, 2)} TRI`}
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
                <span className="text-[#8892a4] font-medium">TRI</span>
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
                {loading === "approve" ? "Approving..." : `Approve ${amount || "0"} TRI`}
              </button>
            ) : action === "stake" && step === "approved" ? (
              <button
                onClick={handleStake}
                disabled={loading !== null}
                className="w-full py-3 rounded-lg bg-[#4ecca3] text-black font-medium disabled:opacity-50"
              >
                {loading === "stake" ? "Staking..." : `Stake ${amount} TRI`}
              </button>
            ) : action === "withdraw" ? (
              <button
                onClick={handleWithdraw}
                disabled={loading !== null || parsedAmount === 0n}
                className="w-full py-3 rounded-lg bg-[#e94560] text-white font-medium disabled:opacity-50"
              >
                {loading === "withdraw" ? "Withdrawing..." : "Withdraw TRI"}
              </button>
            ) : null}

            {/* Claim / Exit */}
            {isConnected && hasEarnings && (
              <div className="flex gap-2">
                <button
                  onClick={handleClaim}
                  disabled={loading !== null}
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
        </div>
      </main>
    </div>
  );
}
