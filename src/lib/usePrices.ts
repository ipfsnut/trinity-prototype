"use client";

import { useEffect, useState } from "react";
import { usePublicClient } from "wagmi";
import { formatUnits, parseUnits } from "viem";
import { ADDRESSES, POOLS, QUOTER_ABI, isTriCurrency0 } from "./contracts";

export interface Prices {
  triniUsd: number | null;
  wethUsd: number | null;
  clankerUsd: number | null;
}

async function quoteTriniToAsset(
  client: NonNullable<ReturnType<typeof usePublicClient>>,
  pool: (typeof POOLS)[keyof typeof POOLS],
  amount: bigint
): Promise<bigint> {
  const result = await client.simulateContract({
    address: ADDRESSES.quoter,
    abi: QUOTER_ABI,
    functionName: "quoteExactInputSingle",
    args: [{
      poolKey: pool.poolKey,
      zeroForOne: isTriCurrency0(pool.quoteAsset),
      exactAmount: amount,
      hookData: "0x",
    }],
  });
  return result.result[0];
}

export function usePrices(): Prices {
  const publicClient = usePublicClient();
  const [prices, setPrices] = useState<Prices>({
    triniUsd: null,
    wethUsd: null,
    clankerUsd: null,
  });

  useEffect(() => {
    if (!publicClient) return;
    const client = publicClient;

    async function fetchPrices() {
      const quoteAmount = parseUnits("1000000", 18); // 1M TRINI
      let triniUsd: number | null = null;
      let wethUsd: number | null = null;

      // Step 1: TRINI price in USD (required for everything else)
      try {
        const usdcOut = await quoteTriniToAsset(client, POOLS.usdc, quoteAmount);
        triniUsd = Number(formatUnits(usdcOut, 6)) / 1_000_000;
      } catch (e) {
        console.error("[usePrices] TRINI/USDC quote failed:", e);
      }

      if (triniUsd === null || triniUsd === 0) {
        setPrices({ triniUsd, wethUsd, clankerUsd: null });
        return;
      }

      // Step 2: WETH price — try on-chain quote, fall back to CoinGecko
      try {
        const wethOut = await quoteTriniToAsset(client, POOLS.eth, quoteAmount);
        const wethOutNum = Number(formatUnits(wethOut, 18));
        if (wethOutNum > 0) {
          wethUsd = (1_000_000 * triniUsd) / wethOutNum;
        }
      } catch {
        // Quoter failed (public RPC timeout) — use CoinGecko as fallback
        try {
          const res = await fetch("https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd");
          const data = await res.json();
          if (data?.ethereum?.usd) wethUsd = data.ethereum.usd;
        } catch {
          console.error("[usePrices] Both WETH price sources failed");
        }
      }

      // Step 3: CLANKER price
      let clankerUsd: number | null = null;
      try {
        const clkOut = await quoteTriniToAsset(client, POOLS.clanker, quoteAmount);
        const clkOutNum = Number(formatUnits(clkOut, 18));
        if (clkOutNum > 0) {
          clankerUsd = (1_000_000 * triniUsd) / clkOutNum;
        }
      } catch (e) {
        console.error("[usePrices] TRINI/Clanker quote failed:", e);
      }

      setPrices({ triniUsd, wethUsd, clankerUsd });
    }

    fetchPrices();
    const interval = setInterval(fetchPrices, 60_000);
    return () => clearInterval(interval);
  }, [publicClient]);

  return prices;
}
