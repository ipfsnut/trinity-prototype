"use client";

import { useState } from "react";
import {
  useAccount,
  usePublicClient,
  useWalletClient,
  useReadContracts,
} from "wagmi";
import { formatUnits, parseUnits, encodeFunctionData } from "viem";
import {
  ADDRESSES,
  stakingHubAdminAbi,
  rewardGaugeAbi,
  erc20Abi,
} from "@/lib/contracts";

const MULTISIG = "0xb7DD467A573809218aAE30EB2c60e8AE3a9198a0";
const CLANKER = ADDRESSES.clanker;
const WETH = ADDRESSES.weth;
const CLANKER_GAUGE = ADDRESSES.clankerGauge;

export function AdminPanel() {
  const { address } = useAccount();
  const publicClient = usePublicClient();
  const { data: walletClient } = useWalletClient();
  const [loading, setLoading] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [wethAmount, setWethAmount] = useState("");
  const [clankerAmount, setClankerAmount] = useState("");

  if (!address || address.toLowerCase() !== MULTISIG.toLowerCase()) {
    return null;
  }

  const { data: gaugeData, refetch: refetchGauges } = useReadContracts({
    contracts: [
      { address: ADDRESSES.wethGauge, abi: rewardGaugeAbi, functionName: "rewardRate" },
      { address: ADDRESSES.wethGauge, abi: rewardGaugeAbi, functionName: "periodFinish" },
      { address: WETH, abi: erc20Abi, functionName: "balanceOf", args: [MULTISIG as `0x${string}`] },
      { address: CLANKER, abi: erc20Abi, functionName: "balanceOf", args: [MULTISIG as `0x${string}`] },
      { address: CLANKER_GAUGE, abi: rewardGaugeAbi, functionName: "rewardRate" },
      { address: CLANKER_GAUGE, abi: rewardGaugeAbi, functionName: "periodFinish" },
      // Check existing approvals
      { address: WETH, abi: erc20Abi, functionName: "allowance", args: [MULTISIG as `0x${string}`, ADDRESSES.wethGauge] },
      { address: CLANKER, abi: erc20Abi, functionName: "allowance", args: [MULTISIG as `0x${string}`, CLANKER_GAUGE] },
    ],
  });

  const wethRewardRate = gaugeData?.[0]?.result as bigint | undefined;
  const wethPeriodFinish = gaugeData?.[1]?.result as bigint | undefined;
  const multisigWeth = gaugeData?.[2]?.result as bigint | undefined;
  const multisigChaoslp = gaugeData?.[3]?.result as bigint | undefined;
  const clankerRewardRate = gaugeData?.[4]?.result as bigint | undefined;
  const clankerPeriodFinish = gaugeData?.[5]?.result as bigint | undefined;
  const wethAllowance = gaugeData?.[6]?.result as bigint | undefined;
  const clankerAllowance = gaugeData?.[7]?.result as bigint | undefined;

  const wethGaugeActive = wethPeriodFinish !== undefined && Number(wethPeriodFinish) > Date.now() / 1000;
  const clankerGaugeActive = clankerPeriodFinish !== undefined && Number(clankerPeriodFinish) > Date.now() / 1000;

  const parsedWeth = wethAmount ? parseUnits(wethAmount, 18) : 0n;
  const parsedClanker = clankerAmount ? parseUnits(clankerAmount, 18) : 0n;

  const wethApproved = wethAllowance !== undefined && parsedWeth > 0n && wethAllowance >= parsedWeth;
  const clankerApproved = clankerAllowance !== undefined && parsedClanker > 0n && clankerAllowance >= parsedClanker;

  const fmt = (val: bigint | undefined, dec: number, dp = 4) =>
    val !== undefined ? Number(formatUnits(val, dec)).toFixed(dp) : "—";

  // Safe-friendly: just send the tx and show success immediately.
  // Safe returns a proposal hash, not a mined tx hash. Don't wait for receipt.
  async function safeSend(to: `0x${string}`, data: `0x${string}`, label: string) {
    if (!walletClient) throw new Error("No wallet");
    setLoading(label); setError(null); setSuccess(null);
    try {
      await walletClient.sendTransaction({
        to,
        data,
        chain: walletClient.chain,
        account: walletClient.account,
      });
      setSuccess(`${label} — tx proposed. Sign in Safe to execute.`);
      // Refresh data after a delay (give time for execution)
      setTimeout(() => refetchGauges(), 5000);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Failed");
    } finally {
      setLoading(null);
    }
  }

  // ── Individual actions ──────────────────────────────────────────

  function approveWeth() {
    const data = encodeFunctionData({
      abi: erc20Abi,
      functionName: "approve",
      args: [ADDRESSES.wethGauge, parsedWeth],
    });
    safeSend(WETH, data, "Approve WETH");
  }

  function fundWeth() {
    const data = encodeFunctionData({
      abi: rewardGaugeAbi,
      functionName: "notifyRewardAmount",
      args: [parsedWeth],
    });
    safeSend(ADDRESSES.wethGauge, data, "Fund WETH gauge");
  }

  function approveClanker() {
    const data = encodeFunctionData({
      abi: erc20Abi,
      functionName: "approve",
      args: [CLANKER_GAUGE, parsedClanker],
    });
    safeSend(CLANKER, data, "Approve $CLANKER");
  }

  function fundClanker() {
    const data = encodeFunctionData({
      abi: rewardGaugeAbi,
      functionName: "notifyRewardAmount",
      args: [parsedClanker],
    });
    safeSend(CLANKER_GAUGE, data, "Fund $CLANKER gauge");
  }

  function registerChaoslpGauge() {
    const data = encodeFunctionData({
      abi: stakingHubAdminAbi,
      functionName: "addExtraReward",
      args: [CLANKER_GAUGE],
    });
    safeSend(ADDRESSES.stakingHub, data, "Register $CLANKER gauge");
  }

  return (
    <div className="mt-8 bg-[#1a0a1a] rounded-xl p-5 border border-[#533483] space-y-4">
      <div className="flex justify-between items-center">
        <div className="text-sm font-bold text-[#533483]">Multisig Admin</div>
        <button onClick={() => refetchGauges()}
          className="text-xs text-[#8892a4] hover:text-white transition-colors">
          Refresh
        </button>
      </div>

      {/* Multisig balances */}
      <div className="grid grid-cols-2 gap-3 text-xs">
        <div className="bg-[#0d1117] rounded-lg p-3 border border-[#0f3460]">
          <div className="text-[#8892a4]">Multisig WETH</div>
          <div className="text-white font-mono">{fmt(multisigWeth, 18, 6)}</div>
        </div>
        <div className="bg-[#0d1117] rounded-lg p-3 border border-[#0f3460]">
          <div className="text-[#8892a4]">Multisig $CLANKER</div>
          <div className="text-white font-mono">{fmt(multisigChaoslp, 18, 2)}</div>
        </div>
      </div>

      {/* WETH Gauge */}
      <div className="bg-[#0d1117] rounded-lg p-4 border border-[#0f3460] space-y-3">
        <div className="flex justify-between items-center">
          <span className="text-sm text-[#4e9af0] font-medium">WETH Gauge</span>
          <span className={`text-xs font-mono ${wethGaugeActive ? "text-[#4ecca3]" : "text-[#8892a4]"}`}>
            {wethGaugeActive ? `Streaming — ${fmt(wethRewardRate! * 86400n, 18, 6)}/day` : "Not funded"}
          </span>
        </div>
        <div className="flex gap-2 items-center">
          <input type="text" inputMode="decimal" placeholder="WETH amount"
            value={wethAmount} onChange={(e) => setWethAmount(e.target.value)}
            className="flex-1 bg-[#16213e] text-white text-sm font-mono rounded-lg px-3 py-2 outline-none border border-[#0f3460]" />
          {!wethApproved ? (
            <button onClick={approveWeth} disabled={loading !== null || parsedWeth === 0n}
              className="px-4 py-2 rounded-lg bg-[#f0c040] text-black text-sm font-medium disabled:opacity-50">
              Approve
            </button>
          ) : (
            <button onClick={fundWeth} disabled={loading !== null || parsedWeth === 0n}
              className="px-4 py-2 rounded-lg bg-[#4e9af0] text-white text-sm font-medium disabled:opacity-50">
              Fund
            </button>
          )}
        </div>
        <div className="flex gap-1">
          {[25, 50, 75, 100].map((pct) => (
            <button key={pct} disabled={!multisigWeth}
              onClick={() => {
                if (!multisigWeth) return;
                const val = pct === 100 ? multisigWeth : multisigWeth * BigInt(pct) / 100n;
                setWethAmount(formatUnits(val, 18));
              }}
              className="flex-1 py-1 text-xs rounded bg-[#16213e] text-[#8892a4] hover:text-white disabled:opacity-30 transition-colors"
            >{pct}%</button>
          ))}
        </div>
      </div>

      {/* ChaosLP Gauge */}
      <div className="bg-[#0d1117] rounded-lg p-4 border border-[#0f3460] space-y-3">
        <div className="flex justify-between items-center">
          <span className="text-sm text-[#e94560] font-medium">$CLANKER Gauge</span>
          <span className={`text-xs font-mono ${clankerGaugeActive ? "text-[#4ecca3]" : "text-[#8892a4]"}`}>
            {clankerGaugeActive ? `Streaming — ${fmt(clankerRewardRate! * 86400n, 18, 2)}/day` : "Not funded"}
          </span>
        </div>
        <div className="text-xs text-[#8892a4] font-mono break-all">
          Gauge: {CLANKER_GAUGE}
        </div>
        <div className="flex gap-2 items-center">
          <input type="text" inputMode="decimal" placeholder="$CLANKER amount"
            value={clankerAmount} onChange={(e) => setClankerAmount(e.target.value)}
            className="flex-1 bg-[#16213e] text-white text-sm font-mono rounded-lg px-3 py-2 outline-none border border-[#0f3460]" />
          {!clankerApproved ? (
            <button onClick={approveClanker} disabled={loading !== null || parsedClanker === 0n}
              className="px-4 py-2 rounded-lg bg-[#f0c040] text-black text-sm font-medium disabled:opacity-50">
              Approve
            </button>
          ) : (
            <button onClick={fundClanker} disabled={loading !== null || parsedClanker === 0n}
              className="px-4 py-2 rounded-lg bg-[#e94560] text-white text-sm font-medium disabled:opacity-50">
              Fund
            </button>
          )}
        </div>
        <div className="flex gap-1">
          {[25, 50, 75, 100].map((pct) => (
            <button key={pct} disabled={!multisigChaoslp}
              onClick={() => {
                if (!multisigChaoslp) return;
                const val = pct === 100 ? multisigChaoslp : multisigChaoslp * BigInt(pct) / 100n;
                setClankerAmount(formatUnits(val, 18));
              }}
              className="flex-1 py-1 text-xs rounded bg-[#16213e] text-[#8892a4] hover:text-white disabled:opacity-30 transition-colors"
            >{pct}%</button>
          ))}
        </div>
      </div>

      {/* Status */}
      {loading && (
        <div className="text-sm text-[#f0c040] bg-[#0d1117] rounded-lg p-3 border border-[#f0c040]/30">
          {loading}...
        </div>
      )}
      {error && (
        <div className="text-sm text-[#e94560] bg-[#0d1117] rounded-lg p-3 border border-[#e94560]/30 break-all">
          {error}
        </div>
      )}
      {success && (
        <div className="text-sm text-[#4ecca3] bg-[#0d1117] rounded-lg p-3 border border-[#4ecca3]/30">
          {success}
        </div>
      )}
    </div>
  );
}
