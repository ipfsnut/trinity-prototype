import { parseAbi } from "viem";

// ── V6 Deployed addresses (Base mainnet) ────────────────────────────
export const ADDRESSES = {
  trini: "0x17790eFD4896A981Db1d9607A301BC4F7407F3dF" as `0x${string}`,
  hook: "0xe89a658e4bec91caea242aD032280a5D3015C8c8" as `0x${string}`,
  stakingHub: "0x76F63BB9990a1afdB1c426394D3Fc2448FBe77d6" as `0x${string}`,
  wethGauge: "0x97F6f66d2BD30a87D6C4581390343e9cA02c7ae2" as `0x${string}`,
  // V4 infrastructure on Base
  universalRouter: "0x6ff5693b99212da76ad316178a184ab56d299b43" as `0x${string}`,
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3" as `0x${string}`,
  quoter: "0x0d5e0F971ED27FBfF6c2837bf31316121532048D" as `0x${string}`,
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
]);

// ── V4 Pool Keys (tickSpacing=200, fee=0, with hook) ────────────────

export function makePoolKey(quoteAsset: `0x${string}`) {
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
    hooks: ADDRESSES.hook,
  };
}

// ── Pool config ─────────────────────────────────────────────────────
export type PoolId = "usdc" | "eth" | "chaoslp";

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
  }
> = {
  usdc: {
    label: "TRINI / USDC",
    quoteSymbol: "USDC",
    quoteAsset: ADDRESSES.usdc,
    poolKey: makePoolKey(ADDRESSES.usdc),
    quoteDecimals: 6,
    color: "#4ecca3",
    geckoUrl: "https://www.geckoterminal.com/base/pools/0xd35b828aa74cd7832be68003ce44de7767987a27b8ef654ca6c595e7584a156e",
  },
  eth: {
    label: "TRINI / ETH",
    quoteSymbol: "ETH",
    quoteAsset: ADDRESSES.weth,
    poolKey: makePoolKey(ADDRESSES.weth),
    quoteDecimals: 18,
    color: "#4e9af0",
    geckoUrl: "https://www.geckoterminal.com/base/pools/0x00275064520d3ef7a2f653ef850f1589bcbdb3b346cd1e6bc96f888d204ff149",
  },
  chaoslp: {
    label: "TRINI / $CHAOSLP",
    quoteSymbol: "$CHAOSLP",
    quoteAsset: ADDRESSES.chaoslp,
    poolKey: makePoolKey(ADDRESSES.chaoslp),
    quoteDecimals: 18,
    color: "#e94560",
    geckoUrl: "https://www.geckoterminal.com/base/pools/0x82b8764cf567ba42de55e6113efcadc9c5526c748f781ff24b9bc174bfc51bd4",
  },
};

// ── Universal Router V4 Swap Encoding ───────────────────────────────
// Command 0x10 = V4_SWAP
// Actions: SWAP_EXACT_IN_SINGLE(0x06) + SETTLE(0x0b) + TAKE(0x0e)

export const V4_SWAP_COMMAND = "0x10" as `0x${string}`;

export function isTriCurrency0(quoteAsset: `0x${string}`): boolean {
  return ADDRESSES.trini.toLowerCase() < quoteAsset.toLowerCase();
}
