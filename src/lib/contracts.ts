import { parseAbi } from "viem";

// ── V2 Deployed addresses (Base mainnet) ────────────────────────────
export const ADDRESSES = {
  tri: "0x52F69f6f8F30978A1F694f10dc5d8d45ECc0c0e9" as `0x${string}`,
  hook: "0xb000F242eefBD4467B13a4B0c758c048EAcdC088" as `0x${string}`,
  router: "0xD509db41d238CdD466ca0DF36Ff04E5040b6a067" as `0x${string}`,
  stakingHub: "0x3a4C8Ee124e9051Ae26A2CaD5f1F7EF4EF7F6A49" as `0x${string}`,
  wethGauge: "0x67B239Ef51d2A6587d9d3Def70070C57eE354B0D" as `0x${string}`,
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

// TrinityHook — read curve state per pool
export const trinityHookAbi = parseAbi([
  "function getCurve(bytes32 id) view returns (uint256 basePrice, uint256 slope, uint256 maxSupply, uint256 totalSold, uint256 totalBurned, address feeRecipient, uint8 quoteDecimals, bool triIsCurrency0, bool active)",
  "function tri() view returns (address)",
]);

// TrinityRouter — swap via V4 PoolManager (supports native ETH wrapping)
export const trinityRouterAbi = parseAbi([
  "function buyTri((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint256 quoteAmount, uint256 minTriOut, address triToken) returns (uint256 triOut)",
  "function buyTriWithETH((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint256 minTriOut, address triToken) payable returns (uint256 triOut)",
  "function sellTri((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint256 triAmount, uint256 minQuoteOut, address triToken) returns (uint256 quoteOut)",
  "function sellTriForETH((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint256 triAmount, uint256 minEthOut, address triToken) returns (uint256 ethOut)",
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

// ── V4 Pool Keys ────────────────────────────────────────────────────
// PoolKey struct: (currency0, currency1, fee, tickSpacing, hooks)
// V4 requires currency0 < currency1

function makePoolKey(quoteAsset: `0x${string}`): {
  currency0: `0x${string}`;
  currency1: `0x${string}`;
  fee: number;
  tickSpacing: number;
  hooks: `0x${string}`;
} {
  const tri = ADDRESSES.tri.toLowerCase();
  const quote = quoteAsset.toLowerCase();
  const [c0, c1] =
    tri < quote
      ? [ADDRESSES.tri, quoteAsset]
      : [quoteAsset, ADDRESSES.tri];
  return {
    currency0: c0,
    currency1: c1,
    fee: 0,
    tickSpacing: 1,
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
    supply: bigint;
    basePrice: bigint;
    slope: bigint;
    color: string;
  }
> = {
  usdc: {
    label: "TRI / USDC",
    quoteSymbol: "USDC",
    quoteAsset: ADDRESSES.usdc,
    poolKey: makePoolKey(ADDRESSES.usdc),
    quoteDecimals: 6,
    supply: 334_000_000n * 10n ** 18n,
    basePrice: 100_000_000_000_000n,
    slope: 49_500_000n,
    color: "#4ecca3",
  },
  eth: {
    label: "TRI / WETH",
    quoteSymbol: "WETH",
    quoteAsset: ADDRESSES.weth,
    poolKey: makePoolKey(ADDRESSES.weth),
    quoteDecimals: 18,
    supply: 333_000_000n * 10n ** 18n,
    basePrice: 48_500_000_000n,
    slope: 16_000n,
    color: "#4e9af0",
  },
  chaoslp: {
    label: "TRI / $CHAOSLP",
    quoteSymbol: "$CHAOSLP",
    quoteAsset: ADDRESSES.chaoslp,
    poolKey: makePoolKey(ADDRESSES.chaoslp),
    quoteDecimals: 18,
    supply: 233_000_000n * 10n ** 18n,
    basePrice: 3_889_770_000_000_000_000_000n,
    slope: 1_280_000_000_000_000n,
    color: "#e94560",
  },
};

// ── Curve math (mirrors TrinityHook.sol) ────────────────────────────
const WAD = 10n ** 18n;

function sqrt(x: bigint): bigint {
  if (x === 0n) return 0n;
  let z = x;
  let y = (z + 1n) / 2n;
  while (y < z) {
    z = y;
    y = (x / y + y) / 2n;
  }
  return z;
}

function toWad(amount: bigint, decimals: number): bigint {
  if (decimals === 18) return amount;
  return amount * 10n ** BigInt(18 - decimals);
}

function fromWad(wadAmount: bigint, decimals: number): bigint {
  if (decimals === 18) return wadAmount;
  return wadAmount / 10n ** BigInt(18 - decimals);
}

/** Compute TRI output for a given quote input (after 1% fee). */
export function quoteTokensOut(
  quoteIn: bigint,
  totalSold: bigint,
  basePrice: bigint,
  slope: bigint,
  quoteDecimals: number
): bigint {
  const fee = (quoteIn * 100n) / 10_000n;
  const net = quoteIn - fee;
  const netWad = toWad(net, quoteDecimals);
  if (netWad === 0n) return 0n;

  const K = (2n * WAD * basePrice) / slope + 2n * totalSold;
  const L = (2n * WAD) * ((WAD * netWad) / slope);
  const disc = K * K + 4n * L;
  const sqrtDisc = sqrt(disc);
  return (sqrtDisc - K) / 2n;
}

/** Compute quote output for a given TRI sell amount (after 1% burn). */
export function quoteAssetOut(
  triIn: bigint,
  totalSold: bigint,
  basePrice: bigint,
  slope: bigint,
  quoteDecimals: number
): bigint {
  const burnAmount = (triIn * 100n) / 10_000n;
  const sellAmount = triIn - burnAmount;
  if (sellAmount === 0n || sellAmount > totalSold) return 0n;

  const sumTerms = 2n * totalSold - sellAmount;
  const baseCost = (basePrice * sellAmount) / WAD;
  const slopeCost = ((slope * sellAmount) / WAD) * sumTerms / (2n * WAD);
  return fromWad(baseCost + slopeCost, quoteDecimals);
}

/** Spot price in WAD (quote per TRI). */
export function spotPrice(totalSold: bigint, basePrice: bigint, slope: bigint): bigint {
  return basePrice + (slope * totalSold) / WAD;
}
