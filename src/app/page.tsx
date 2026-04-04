"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";
import { TradePanel } from "@/components/TradePanel";
import Link from "next/link";

export default function Home() {
  return (
    <div className="min-h-screen flex flex-col">
      {/* Nav */}
      <nav className="flex items-center justify-between px-6 py-4 border-b border-[#0f3460]">
        <div className="flex items-center gap-6">
          <span className="text-xl font-bold text-white">Trinity</span>
          <div className="flex gap-4 text-sm">
            <Link href="/" className="text-[#e94560] font-medium">
              Trade
            </Link>
            <Link
              href="/stake"
              className="text-[#8892a4] hover:text-white transition-colors"
            >
              Stake
            </Link>
            <Link
              href="/docs"
              className="text-[#8892a4] hover:text-white transition-colors"
            >
              Docs
            </Link>
          </div>
        </div>
        <ConnectButton />
      </nav>

      {/* Main */}
      <main className="flex-1 flex items-start justify-center pt-12 px-4">
        <div className="w-full max-w-md">
          <div className="mb-6">
            <h1 className="text-2xl font-bold text-white">Trade $TRI</h1>
            <p className="text-sm text-[#8892a4]">
              Three curves. 1% fee. Every sell burns.
            </p>
            <div className="mt-2 flex items-center gap-2 text-xs text-[#8892a4] bg-[#0d1117] rounded-lg px-3 py-2 border border-[#0f3460]">
              <span>TRI:</span>
              <code className="text-[#4ecca3] font-mono">0x52F69f6f8F30978A1F694f10dc5d8d45ECc0c0e9</code>
              <a
                href="https://basescan.org/token/0x52F69f6f8F30978A1F694f10dc5d8d45ECc0c0e9"
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
        </div>
      </main>
    </div>
  );
}
