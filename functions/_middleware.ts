// Cloudflare Pages Middleware — serves Farcaster Snap JSON on /
// Uses raw eth_call instead of viem (Workers-compatible, no node deps)

const RPCS = [
  "https://base.drpc.org",
  "https://base.llamarpc.com",
  "https://mainnet.base.org",
  "https://base-rpc.publicnode.com",
];
const SITE_URL = "https://trinity-prototype.epicdylan.com";

const ADDRESSES = {
  trini: "0x17790eFD4896A981Db1d9607A301BC4F7407F3dF",
  hook: "0xe89a658e4bec91caea242aD032280a5D3015C8c8",
  stakingHub: "0x76F63BB9990a1afdB1c426394D3Fc2448FBe77d6",
  chaoslpGauge: "0xa142dcE717820F0f92E5f89d9aFA7B61A4FA1904",
  wethGauge: "0x97F6f66d2BD30a87D6C4581390343e9cA02c7ae2",
  quoter: "0x0d5e0F971ED27FBfF6c2837bf31316121532048D",
  usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  dead: "0x000000000000000000000000000000000000dEaD",
};

// ── Raw RPC helpers ──────────────────────────────────────────────

async function ethCall(to: string, data: string): Promise<string> {
  for (const rpc of RPCS) {
    try {
      const res = await fetch(rpc, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          jsonrpc: "2.0", id: 1, method: "eth_call",
          params: [{ to, data }, "latest"],
        }),
      });
      const json = await res.json() as { result?: string; error?: { message: string } };
      if (json.error) continue;
      if (json.result && json.result !== "0x") return json.result;
    } catch { continue; }
  }
  throw new Error("All RPCs failed");
}

function decodeUint256(hex: string): bigint {
  if (hex === "0x" || hex.length < 66) return 0n;
  return BigInt("0x" + hex.slice(2, 66));
}

// totalSupply() = 0x18160ddd
// balanceOf(address) = 0x70a08231 + padded address
// rewardRate() = 0x7b0a47ee
// periodFinish() = 0xebe2b12b
function balanceOfData(addr: string): string {
  return "0x70a08231" + addr.slice(2).toLowerCase().padStart(64, "0");
}

// ── Quoter calldata (pre-encoded via cast, 1M TRINI input) ───────
// quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))
// All quotes: zeroForOne=true (TRINI is currency0 in all pools), exactAmount=1M*1e18

const QUOTE_USDC = "0xaa9d21cb000000000000000000000000000000000000000000000000000000000000002000000000000000000000000017790efd4896a981db1d9607a301bc4f7407f3df000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c8000000000000000000000000e89a658e4bec91caea242ad032280a5d3015c8c8000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000d3c21bcecceda100000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000";

const QUOTE_CLP = "0xaa9d21cb000000000000000000000000000000000000000000000000000000000000002000000000000000000000000017790efd4896a981db1d9607a301bc4f7407f3df0000000000000000000000008454d062506a27675706148ecdd194e45e44067a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c8000000000000000000000000e89a658e4bec91caea242ad032280a5d3015c8c8000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000d3c21bcecceda100000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000";

const QUOTE_WETH = "0xaa9d21cb000000000000000000000000000000000000000000000000000000000000002000000000000000000000000017790efd4896a981db1d9607a301bc4f7407f3df0000000000000000000000004200000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c8000000000000000000000000e89a658e4bec91caea242ad032280a5d3015c8c8000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000d3c21bcecceda100000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000";

// ── Data fetching ────────────────────────────────────────────────

interface SnapData {
  triniPrice: string;
  totalStaked: string;
  stakedPct: string;
  burned: string;
  chaoslpApr: string;
  wethApr: string;
}

const YEAR_SECS = 365n * 86400n;

async function fetchSnapData(): Promise<SnapData> {
  // Parallel reads
  const [supplyHex, stakedHex, burnedHex, clpRateHex, clpFinishHex, wethRateHex, wethFinishHex] =
    await Promise.all([
      ethCall(ADDRESSES.trini, "0x18160ddd"),
      ethCall(ADDRESSES.stakingHub, "0x18160ddd"),
      ethCall(ADDRESSES.trini, balanceOfData(ADDRESSES.dead)),
      ethCall(ADDRESSES.chaoslpGauge, "0x7b0a47ee"),
      ethCall(ADDRESSES.chaoslpGauge, "0xebe2b12b"),
      ethCall(ADDRESSES.wethGauge, "0x7b0a47ee"),
      ethCall(ADDRESSES.wethGauge, "0xebe2b12b"),
    ]);

  const totalSupply = decodeUint256(supplyHex);
  const totalStaked = decodeUint256(stakedHex);
  const burned = decodeUint256(burnedHex);
  const clpRate = decodeUint256(clpRateHex);
  const clpFinish = decodeUint256(clpFinishHex);
  const wethRate = decodeUint256(wethRateHex);
  const wethFinish = decodeUint256(wethFinishHex);

  // TRINI price: quote 1M TRINI → USDC
  let triniUsd = 0;
  let chaoslpUsd = 0;
  let wethUsd = 0;

  try {
    const resultHex = await ethCall(ADDRESSES.quoter, QUOTE_USDC);
    const usdcOut = decodeUint256(resultHex);
    triniUsd = Number(usdcOut) / 1e6 / 1_000_000;
  } catch {}

  if (triniUsd > 0) {
    try {
      const resultHex = await ethCall(ADDRESSES.quoter, QUOTE_CLP);
      const clpOut = Number(decodeUint256(resultHex)) / 1e18;
      if (clpOut > 0) chaoslpUsd = (1_000_000 * triniUsd) / clpOut;
    } catch {}

    try {
      const resultHex = await ethCall(ADDRESSES.quoter, QUOTE_WETH);
      const wethOut = Number(decodeUint256(resultHex)) / 1e18;
      if (wethOut > 0) wethUsd = (1_000_000 * triniUsd) / wethOut;
    } catch {}
  }

  const stakedNum = Number(totalStaked) / 1e18;
  const supplyNum = Number(totalSupply) / 1e18;
  const stakedPct = supplyNum > 0 ? (stakedNum / supplyNum) * 100 : 0;
  const burnedNum = Number(burned) / 1e18;
  const stakedUsd = stakedNum * triniUsd;

  const now = BigInt(Math.floor(Date.now() / 1000));

  let chaoslpApr = 0;
  if (clpFinish > now && stakedUsd > 0 && chaoslpUsd > 0) {
    const annualClp = Number(clpRate * YEAR_SECS) / 1e18;
    chaoslpApr = (annualClp * chaoslpUsd) / stakedUsd * 100;
  }

  let wethApr = 0;
  if (wethFinish > now && stakedUsd > 0 && wethUsd > 0) {
    const annualWeth = Number(wethRate * YEAR_SECS) / 1e18;
    wethApr = (annualWeth * wethUsd) / stakedUsd * 100;
  }

  return {
    triniPrice: triniUsd > 0 ? `$${triniUsd.toFixed(6)}` : "—",
    totalStaked: stakedNum > 1_000_000 ? `${(stakedNum / 1_000_000).toFixed(2)}M` : `${stakedNum.toFixed(0)}`,
    stakedPct: `${stakedPct.toFixed(1)}%`,
    burned: burnedNum > 1_000_000 ? `${(burnedNum / 1_000_000).toFixed(2)}M` : `${Math.floor(burnedNum).toLocaleString()}`,
    chaoslpApr: chaoslpApr > 0 ? `${chaoslpApr.toFixed(1)}%` : "—",
    wethApr: wethApr > 0 ? `${wethApr.toFixed(1)}%` : "—",
  };
}

// ── Snap builder ─────────────────────────────────────────────────

function buildSnap(data: SnapData) {
  return {
    version: "1.0",
    theme: { accent: "green" },
    ui: {
      root: "page",
      elements: {
        page: {
          type: "stack", props: { gap: "sm" },
          children: ["header", "price-row", "sep1", "staking-header", "staking-row", "apr-row", "sep2", "actions"],
        },
        header: { type: "text", props: { content: "Trinity Protocol", weight: "bold" } },
        "price-row": { type: "item", props: { title: "TRINI Price", description: data.triniPrice } },
        sep1: { type: "separator", props: {} },
        "staking-header": { type: "text", props: { content: "Staking", weight: "bold", size: "sm" } },
        "staking-row": {
          type: "stack", props: { direction: "horizontal" },
          children: ["staked-item", "burned-item"],
        },
        "staked-item": { type: "item", props: { title: "Staked", description: `${data.totalStaked} (${data.stakedPct})` } },
        "burned-item": { type: "item", props: { title: "Burned", description: data.burned } },
        "apr-row": {
          type: "stack", props: { direction: "horizontal" },
          children: ["clp-apr", "weth-apr"],
        },
        "clp-apr": { type: "item", props: { title: "$CHAOSLP APR", description: data.chaoslpApr } },
        "weth-apr": { type: "item", props: { title: "WETH APR", description: data.wethApr } },
        sep2: { type: "separator", props: {} },
        actions: {
          type: "stack", props: { direction: "horizontal", gap: "sm" },
          children: ["swap-btn", "site-btn"],
        },
        "swap-btn": {
          type: "button", props: { label: "Buy TRINI", variant: "primary" },
          on: { press: { action: "swap_token", params: {
            sellToken: "eip155:8453/erc20:0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
            buyToken: "eip155:8453/erc20:0x17790eFD4896A981Db1d9607A301BC4F7407F3dF",
          } } },
        },
        "site-btn": {
          type: "button", props: { label: "Visit on Web" },
          on: { press: { action: "open_url", params: { target: SITE_URL } } },
        },
      },
    },
  };
}

// ── Cache ────────────────────────────────────────────────────────

let cache: { data: SnapData; ts: number } | null = null;
const CACHE_TTL = 60_000;

// ── Middleware ────────────────────────────────────────────────────

export const onRequest: PagesFunction = async (context) => {
  const url = new URL(context.request.url);
  const accept = context.request.headers.get("accept") || "";

  if (url.pathname !== "/" || !accept.includes("application/vnd.farcaster.snap+json")) {
    // Add Link header on HTML responses so Farcaster discovers snap support
    const response = await context.next();
    if (url.pathname === "/") {
      const newResponse = new Response(response.body, response);
      newResponse.headers.set("Link", `<${SITE_URL}/>; rel="alternate"; type="application/vnd.farcaster.snap+json"`);
      newResponse.headers.set("Vary", "Accept");
      return newResponse;
    }
    return response;
  }

  let data: SnapData;
  try {
    const now = Date.now();
    if (!cache || now - cache.ts > CACHE_TTL) {
      cache = { data: await fetchSnapData(), ts: now };
    }
    data = cache.data;
  } catch {
    // Fallback with no live data
    data = {
      triniPrice: "—", totalStaked: "—", stakedPct: "—",
      burned: "—", chaoslpApr: "—", wethApr: "—",
    };
  }

  return new Response(JSON.stringify(buildSnap(data)), {
    headers: {
      "Content-Type": "application/vnd.farcaster.snap+json",
      "Vary": "Accept",
      "Cache-Control": "public, max-age=60",
    },
  });
};
