"use client";

import { TradePanel } from "@/components/TradePanel";
import { Nav } from "@/components/Nav";

export default function Home() {
  return (
    <div className="min-h-screen flex flex-col">
      <Nav active="trade" />

      {/* Main */}
      <main className="flex-1 flex items-start justify-center pt-12 px-4">
        <div className="w-full max-w-md">
          <div className="mb-6">
            <h1 className="text-2xl font-bold text-white">Trade $TRINI</h1>
            <p className="text-sm text-[#8892a4]">
              Three V8 curves. Continuous liquidity. Every sell burns.
            </p>
            <div className="mt-2 flex items-center gap-2 text-xs text-[#8892a4] bg-[#0d1117] rounded-lg px-3 py-2 border border-[#0f3460]">
              <span>TRINI:</span>
              <code className="text-[#4ecca3] font-mono text-[10px]">0x17790eFD4896A981Db1d9607A301BC4F7407F3dF</code>
              <a
                href="https://basescan.org/token/0x17790eFD4896A981Db1d9607A301BC4F7407F3dF"
                target="_blank"
                rel="noopener noreferrer"
                className="text-[#4e9af0] hover:underline ml-auto"
              >
                Basescan
              </a>
            </div>
          </div>
          <div className="bg-[#16213e] rounded-xl p-5 border border-[#0f3460]">
            <TradePanel />
          </div>

          {/* Contracts */}
          <div className="mt-6 bg-[#0d1117] rounded-xl p-4 border border-[#0f3460] space-y-2 text-xs">
            <div className="text-[#8892a4] font-medium mb-2">Verified Contracts (Base)</div>
            {[
              { label: "TRINI Token", addr: "0x17790eFD4896A981Db1d9607A301BC4F7407F3dF" },
              { label: "TRINI / USDC (1%)", addr: "0x995d479bdd10686BDfeC8E8ba5f86357211bC888" },
              { label: "TRINI / WETH (2%)", addr: "0x089d5FFe033aF0726aAbfAf2276F269D4Fe78888" },
              { label: "TRINI / Clanker (2%)", addr: "0x95911f10849fAB05fdf8d42599B34dC8A17b8888" },
              { label: "Staking Hub", addr: "0x76F63BB9990a1afdB1c426394D3Fc2448FBe77d6" },
            ].map((c) => (
              <div key={c.addr} className="flex justify-between items-center">
                <span className="text-[#8892a4]">{c.label}</span>
                <a
                  href={`https://basescan.org/address/${c.addr}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-[#4e9af0] hover:underline font-mono"
                >
                  {c.addr.slice(0, 6)}...{c.addr.slice(-4)}
                </a>
              </div>
            ))}
          </div>

          {/* Disclaimer */}
          <div className="mt-4 bg-[#1a0a0a] rounded-xl p-4 border border-[#e94560]/30 text-xs text-[#e94560]/80 space-y-2">
            <div className="font-medium text-[#e94560]">Trade at your own risk</div>
            <p>
              This is experimental DeFi. The contracts have not been independently audited &mdash;
              only reviewed by the creator and his computer, and he&apos;s hardly impartial.
              Don&apos;t put in more than you&apos;re comfortable losing entirely.
            </p>
          </div>

          {/* Footer links */}
          <div className="mt-4 flex items-center justify-center gap-4 text-xs text-[#8892a4] pb-8">
            <a href="https://epicdylan.com" target="_blank" rel="noopener noreferrer" className="hover:text-white transition-colors">
              epicdylan.com
            </a>
            <span className="text-[#0f3460]">|</span>
            <a href="https://github.com/ipfsnut/trinity-prototype" target="_blank" rel="noopener noreferrer" className="hover:text-white transition-colors">
              GitHub
            </a>
          </div>
        </div>
      </main>
    </div>
  );
}
