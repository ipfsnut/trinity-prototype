"use client";

import { Nav } from "@/components/Nav";

export default function DocsPage() {
  const docs = [
    {
      title: "Trinity V6 Protocol",
      href: "/docs-trinity.html",
      description: "V6 hook architecture, fee model, burn mechanics, cross-pool arb dynamics, deployed addresses.",
    },
    {
      title: "Source Code (GitHub)",
      href: "https://github.com/ipfsnut/trinity-prototype",
      description: "Full source: TrinityHookV6.sol, TrinityTokenV6.sol, DeployTrinityV6.s.sol, frontend, and documentation.",
    },
    {
      title: "TRINI Token",
      href: "https://basescan.org/token/0x17790eFD4896A981Db1d9607A301BC4F7407F3dF",
      description: "$TRINI — 1B supply, CREATE2 deployed below WETH for currency0 ordering. Verified on Basescan.",
    },
    {
      title: "TrinityHookV6",
      href: "https://basescan.org/address/0xe89a658e4bec91caea242aD032280a5D3015C8c8",
      description: "The V4 hook contract — fee extraction, LP band management, burn on sell. Verified on Basescan.",
    },
    {
      title: "Staking Hub",
      href: "https://basescan.org/address/0x76F63BB9990a1afdB1c426394D3Fc2448FBe77d6",
      description: "Stake TRINI, earn $CHAOSLP + WETH rewards. ChaosLPHub pattern. Verified on Basescan.",
    },
    {
      title: "WETH Reward Gauge",
      href: "https://basescan.org/address/0x97F6f66d2BD30a87D6C4581390343e9cA02c7ae2",
      description: "Distributes WETH rewards to stakers. Verified on Basescan.",
    },
    {
      title: "$CHAOSLP Reward Gauge",
      href: "https://basescan.org/address/0xa142dcE717820F0f92E5f89d9aFA7B61A4FA1904",
      description: "Distributes $CHAOSLP rewards to stakers. 180-day stream. Verified on Basescan.",
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

          {docs.map((doc) => (
            <a
              key={doc.href}
              href={doc.href}
              target="_blank"
              rel="noopener noreferrer"
              className="block bg-[#16213e] rounded-xl p-5 border border-[#0f3460] hover:border-[#4ecca3] transition-colors"
            >
              <h2 className="text-lg font-semibold text-white">{doc.title}</h2>
              <p className="text-sm text-[#8892a4] mt-1">{doc.description}</p>
            </a>
          ))}
        </div>
      </main>
    </div>
  );
}
