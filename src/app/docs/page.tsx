"use client";

import { Nav } from "@/components/Nav";

export default function DocsPage() {
  const docs = [
    {
      title: "Trinity V8 Protocol",
      href: "/blog/v8-continuous-curves",
      description: "V8 continuous-position architecture, fee model, burn mechanics, launcher backbone, cross-pool arb dynamics.",
    },
    {
      title: "$EPIC — First V8 Launch",
      href: "https://epicdylan.com/blog/epic-launch",
      description: "100B tokens, 5 continuous curve pools (USDC/WETH/cbBTC/Clanker/TRINI). The first project on the Trinity launcher backbone.",
    },
    {
      title: "Source Code (GitHub)",
      href: "https://github.com/ipfsnut/trinity-prototype",
      description: "Full source: TrinityHookV8.sol, deploy scripts, frontend, and documentation.",
    },
    {
      title: "TRINI Token",
      href: "https://basescan.org/token/0x17790eFD4896A981Db1d9607A301BC4F7407F3dF",
      description: "$TRINI — 1B supply, CREATE2 deployed below WETH for currency0 ordering. Verified on Basescan.",
    },
    {
      title: "TRINI / USDC Hook (1%)",
      href: "https://basescan.org/address/0x995d479bdd10686BDfeC8E8ba5f86357211bC888",
      description: "V8 continuous-position hook. 1% symmetric fee. Buy fees → treasury, sell fees → burn.",
    },
    {
      title: "TRINI / WETH Hook (2%)",
      href: "https://basescan.org/address/0x089d5FFe033aF0726aAbfAf2276F269D4Fe78888",
      description: "V8 continuous-position hook. 2% symmetric fee. Arb surface for ETH price movements.",
    },
    {
      title: "TRINI / Clanker Hook (2%)",
      href: "https://basescan.org/address/0x95911f10849fAB05fdf8d42599B34dC8A17b8888",
      description: "V8 continuous-position hook. 2% symmetric fee. Highest-vol arb surface.",
    },
    {
      title: "TrinityStakingHub",
      href: "https://basescan.org/address/0x9952A3941624A00714A58C0a371fba81e8bA819A",
      description: "Stake TRINI, earn WETH + CLANKER rewards. 180-day rolling streams. Verified on Basescan.",
    },
    {
      title: "WETH Reward Gauge",
      href: "https://basescan.org/address/0xC5C6eea6929A4Ec8080FE6bBCF3A192169CC5cC8",
      description: "Distributes WETH rewards to TRINI stakers. Verified on Basescan.",
    },
    {
      title: "CLANKER Reward Gauge",
      href: "https://basescan.org/address/0x8E9988AACd83220410bF59eF5E2979d02a67EDC1",
      description: "Distributes CLANKER rewards to TRINI stakers. Verified on Basescan.",
    },
    {
      title: "epicdylan.com",
      href: "https://epicdylan.com",
      description: "Built by epicdylan.",
    },
  ];

  return (
    <div className="min-h-screen flex flex-col">
      <Nav active="docs" />

      <main className="flex-1 flex items-start justify-center pt-12 px-4">
        <div className="w-full max-w-lg space-y-4">
          <h1 className="text-2xl font-bold text-white mb-6">Documentation</h1>
          <div className="bg-[#1a0a0a] rounded-xl p-4 border border-[#e94560]/30 text-xs text-[#e94560]/80 space-y-2">
            <div className="font-medium text-[#e94560]">Trade at your own risk</div>
            <p>
              This is experimental DeFi. The contracts have not been independently audited &mdash;
              only reviewed by the creator and his computer, and he&apos;s hardly impartial.
              Don&apos;t put in more than you&apos;re comfortable losing entirely.
            </p>
          </div>

          {docs.map((doc) => {
            const isExternal = doc.href.startsWith("http");
            return (
              <a
                key={doc.href}
                href={doc.href}
                {...(isExternal ? { target: "_blank", rel: "noopener noreferrer" } : {})}
                className="block bg-[#16213e] rounded-xl p-5 border border-[#0f3460] hover:border-[#4ecca3] transition-colors"
              >
                <h2 className="text-lg font-semibold text-white">{doc.title}</h2>
                <p className="text-sm text-[#8892a4] mt-1">{doc.description}</p>
              </a>
            );
          })}
        </div>
      </main>
    </div>
  );
}
