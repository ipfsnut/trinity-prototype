"use client";

import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { base } from "wagmi/chains";
import { http, fallback } from "wagmi";

export const config = getDefaultConfig({
  appName: "Trinity",
  projectId: "2efb2aeae04a72cb733a24ae9efaaf0e",
  chains: [base],
  transports: {
    [base.id]: fallback([
      http("https://mainnet.base.org", { batch: false }),
      http("https://base.llamarpc.com", { batch: false }),
      http("https://base.drpc.org", { batch: false }),
      http("https://base-rpc.publicnode.com", { batch: false }),
      http("https://1rpc.io/base", { batch: false }),
    ]),
  },
  ssr: false,
});
