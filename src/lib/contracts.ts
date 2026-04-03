import { parseAbi } from "viem";

// ── Deployed addresses (fill after deployment) ──────────────────────
export const ADDRESSES = {
  tri: "0xB08af7FC1C44aa966E2bB1f817C42d51fC0AbD1F" as `0x${string}`,
  usdcCurve: "0x40F4DbE008B876d41Cc34052233e6b4FD6bDc768" as `0x${string}`,
  ethCurve: "0x3f7C76eB2D2E93d2A48916eDcff9316F17178884" as `0x${string}`,
  clpCurve: "0x337A31D45DEec40CCee8E03AB07b3637d3301B3B" as `0x${string}`,
  stakingHub: "0xF3904E16ba22ccb2E187E8d7Da2968FA0B769a93" as `0x${string}`,
  wethGauge: "0xcad85612689A214d7764dae7D893baeB58733ac8" as `0x${string}`,
  // Quote assets on Base
  usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as `0x${string}`,
  weth: "0x4200000000000000000000000000000000000006" as `0x${string}`,
  chaoslp: "0x8454d062506a27675706148ECDd194E45e44067a" as `0x${string}`,
} as const;

// ── ABIs ────────────────────────────────────────────────────────────
export const trinityTokenAbi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
]);

export const bondingCurveAbi = parseAbi([
  "function buy(uint256 quoteAmount, uint256 minTokensOut)",
  "function sell(uint256 trinityAmount, uint256 minQuoteOut)",
  "function currentPrice() view returns (uint256)",
  "function totalSold() view returns (uint256)",
  "function totalBurned() view returns (uint256)",
  "function tokensRemaining() view returns (uint256)",
  "function maxSupply() view returns (uint256)",
  "function quoteTokensOut(uint256 quoteIn) view returns (uint256)",
  "function quoteAssetOut(uint256 triIn) view returns (uint256)",
  "function basePrice() view returns (uint256)",
  "function slope() view returns (uint256)",
  "function quoteDecimals() view returns (uint8)",
  "function initialized() view returns (bool)",
  "function feeRecipient() view returns (address)",
]);

export const stakingHubAbi = parseAbi([
  "function stake(uint256 amount)",
  "function withdraw(uint256 amount)",
  "function getReward()",
  "function exit()",
  "function earned(address account) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function rewardRate() view returns (uint256)",
  "function periodFinish() view returns (uint256)",
  "function rewardsDuration() view returns (uint256)",
  "function extraRewards(uint256 index) view returns (address)",
]);

export const rewardGaugeAbi = parseAbi([
  "function earned(address account) view returns (uint256)",
  "function rewardRate() view returns (uint256)",
  "function periodFinish() view returns (uint256)",
  "function getRewardForDuration() view returns (uint256)",
]);

export const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
]);

// ── Pool config ─────────────────────────────────────────────────────
export type PoolId = "usdc" | "eth" | "chaoslp";

export const POOLS: Record<
  PoolId,
  {
    label: string;
    quoteSymbol: string;
    quoteAsset: `0x${string}`;
    curve: `0x${string}`;
    quoteDecimals: number;
    supply: bigint;
    color: string;
  }
> = {
  usdc: {
    label: "TRI / USDC",
    quoteSymbol: "USDC",
    quoteAsset: ADDRESSES.usdc,
    curve: ADDRESSES.usdcCurve as `0x${string}`,
    quoteDecimals: 6,
    supply: 334_000_000n * 10n ** 18n,
    color: "#4ecca3",
  },
  eth: {
    label: "TRI / WETH",
    quoteSymbol: "WETH",
    quoteAsset: ADDRESSES.weth,
    curve: ADDRESSES.ethCurve,
    quoteDecimals: 18,
    supply: 333_000_000n * 10n ** 18n,
    color: "#4e9af0",
  },
  chaoslp: {
    label: "TRI / $CHAOSLP",
    quoteSymbol: "$CHAOSLP",
    quoteAsset: ADDRESSES.chaoslp,
    curve: ADDRESSES.clpCurve,
    quoteDecimals: 18,
    supply: 233_000_000n * 10n ** 18n,
    color: "#e94560",
  },
};
