"use client";

import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { base } from "wagmi/chains";
import { http } from "wagmi";

const rpcUrl = process.env.NEXT_PUBLIC_BASE_RPC || "https://mainnet.base.org";

export const config = getDefaultConfig({
  appName: "Trinity",
  projectId: "2efb2aeae04a72cb733a24ae9efaaf0e",
  chains: [base],
  transports: {
    [base.id]: http(rpcUrl, { batch: false }),
  },
  ssr: false,
});
