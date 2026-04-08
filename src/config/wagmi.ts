"use client";

import { connectorsForWallets } from "@rainbow-me/rainbowkit";
import {
  injectedWallet,
  rainbowWallet,
  metaMaskWallet,
  walletConnectWallet,
  coinbaseWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { base } from "wagmi/chains";
import { http, fallback, createConfig } from "wagmi";

const PROJECT_ID = "2efb2aeae04a72cb733a24ae9efaaf0e";

const connectors = connectorsForWallets(
  [
    {
      groupName: "Recommended",
      wallets: [injectedWallet, coinbaseWallet, metaMaskWallet],
    },
    {
      groupName: "More",
      wallets: [rainbowWallet, walletConnectWallet],
    },
  ],
  { appName: "Trinity", projectId: PROJECT_ID }
);

export const config = createConfig({
  connectors,
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
