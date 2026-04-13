import { parseAbi } from "viem";

// ── Deployed addresses (Base mainnet) ──────────────────────────────
export const ADDRESSES = {
  trini: "0x17790eFD4896A981Db1d9607A301BC4F7407F3dF" as `0x${string}`,
  // V8 hooks: continuous single-position, $25k–$100M FDV range, single-sided launch
  hookUsdc: "0x995d479bdd10686BDfeC8E8ba5f86357211bC888" as `0x${string}`,
  hookWeth: "0x089d5FFe033aF0726aAbfAf2276F269D4Fe78888" as `0x${string}`,
  hookClanker: "0x95911f10849fAB05fdf8d42599B34dC8A17b8888" as `0x${string}`,
  stakingHub: "0x9952A3941624A00714A58C0a371fba81e8bA819A" as `0x${string}`,
  wethGauge: "0xC5C6eea6929A4Ec8080FE6bBCF3A192169CC5cC8" as `0x${string}`,
  clankerGauge: "0x8E9988AACd83220410bF59eF5E2979d02a67EDC1" as `0x${string}`,
  // V4 infrastructure on Base
  universalRouter: "0x6ff5693b99212da76ad316178a184ab56d299b43" as `0x${string}`,
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3" as `0x${string}`,
  quoter: "0x0d5e0F971ED27FBfF6c2837bf31316121532048D" as `0x${string}`,
  // Quote assets on Base
  usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as `0x${string}`,
  weth: "0x4200000000000000000000000000000000000006" as `0x${string}`,
  clanker: "0x1bc0c42215582d5A085795f4baDbaC3ff36d1Bcb" as `0x${string}`,
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

export const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
]);

// Universal Router V4 — execute(bytes commands, bytes[] inputs, uint256 deadline)
export const universalRouterAbi = parseAbi([
  "function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable",
]);

// V4 Quoter — quoteExactInputSingle
export const quoterAbi = parseAbi([
  "function quoteExactInputSingle(((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, bool zeroForOne, uint128 exactAmount, bytes hookData)) external returns (uint256 amountOut, uint256 gasEstimate)",
]);

// Permit2 — approve
export const permit2Abi = parseAbi([
  "function approve(address token, address spender, uint160 amount, uint48 expiration) external",
  "function allowance(address owner, address token, address spender) view returns (uint160 amount, uint48 expiration, uint48 nonce)",
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
  "function notifyRewardAmount(uint256 reward)",
]);

// ── Admin ABIs (multisig only) ─────────────────────────────────────

export const stakingHubAdminAbi = parseAbi([
  "function notifyRewardAmount(uint256 reward)",
  "function addExtraReward(address gauge)",
  "function removeExtraReward(address gauge)",
  "function owner() view returns (address)",
  "function rewardsDuration() view returns (uint256)",
]);

export const QUOTER_ABI = [{
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

// ── V4 Pool Keys (tickSpacing=200, fee=0, with hook) ────────────────

export function makePoolKey(
  quoteAsset: `0x${string}`,
  hookAddr: `0x${string}`
) {
  const tri = ADDRESSES.trini.toLowerCase();
  const quote = quoteAsset.toLowerCase();
  const [c0, c1] =
    tri < quote
      ? [ADDRESSES.trini, quoteAsset]
      : [quoteAsset, ADDRESSES.trini];
  return {
    currency0: c0,
    currency1: c1,
    fee: 0,
    tickSpacing: 200,
    hooks: hookAddr,
  };
}

// ── Pool config ─────────────────────────────────────────────────────
export type PoolId = "usdc" | "eth" | "clanker";

export const POOLS: Record<
  PoolId,
  {
    label: string;
    quoteSymbol: string;
    quoteAsset: `0x${string}`;
    poolKey: ReturnType<typeof makePoolKey>;
    quoteDecimals: number;
    color: string;
    geckoUrl: string;
    feeLabel: string;
    feeBps: number;
  }
> = {
  usdc: {
    label: "TRINI / USDC",
    quoteSymbol: "USDC",
    quoteAsset: ADDRESSES.usdc,
    poolKey: makePoolKey(ADDRESSES.usdc, ADDRESSES.hookUsdc),
    quoteDecimals: 6,
    color: "#4ecca3",
    geckoUrl: "",
    feeLabel: "1%",
    feeBps: 100,
  },
  eth: {
    label: "TRINI / ETH",
    quoteSymbol: "ETH",
    quoteAsset: ADDRESSES.weth,
    poolKey: makePoolKey(ADDRESSES.weth, ADDRESSES.hookWeth),
    quoteDecimals: 18,
    color: "#4e9af0",
    geckoUrl: "",
    feeLabel: "2%",
    feeBps: 200,
  },
  clanker: {
    label: "TRINI / Clanker",
    quoteSymbol: "CLANKER",
    quoteAsset: ADDRESSES.clanker,
    poolKey: makePoolKey(ADDRESSES.clanker, ADDRESSES.hookClanker),
    quoteDecimals: 18,
    color: "#e94560",
    geckoUrl: "",
    feeLabel: "2%",
    feeBps: 200,
  },
};

// ── Universal Router V4 Swap Encoding ───────────────────────────────
// Command 0x10 = V4_SWAP
// Actions: SWAP_EXACT_IN_SINGLE(0x06) + SETTLE(0x0b) + TAKE(0x0e)

export const V4_SWAP_COMMAND = "0x10" as `0x${string}`;

export function isTriCurrency0(quoteAsset: `0x${string}`): boolean {
  return ADDRESSES.trini.toLowerCase() < quoteAsset.toLowerCase();
}
