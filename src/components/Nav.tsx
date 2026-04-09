"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";
import { SignInButton, useProfile } from "@farcaster/auth-kit";
import Link from "next/link";

export function Nav({ active }: { active: "trade" | "stake" | "docs" | "blog" }) {
  const { isAuthenticated, profile } = useProfile();

  return (
    <nav className="flex items-center justify-between px-6 py-4 border-b border-[#0f3460]">
      <div className="flex items-center gap-6">
        <span className="text-xl font-bold text-white">Trinity</span>
        <div className="flex gap-4 text-sm">
          <Link href="/" className={active === "trade" ? "text-[#e94560] font-medium" : "text-[#8892a4] hover:text-white transition-colors"}>
            Trade
          </Link>
          <Link href="/stake" className={active === "stake" ? "text-[#4ecca3] font-medium" : "text-[#8892a4] hover:text-white transition-colors"}>
            Stake
          </Link>
          <Link href="/docs" className={active === "docs" ? "text-[#f0c040] font-medium" : "text-[#8892a4] hover:text-white transition-colors"}>
            Docs
          </Link>
          <Link href="/blog" className={active === "blog" ? "text-[#00ff41] font-medium" : "text-[#8892a4] hover:text-white transition-colors"}>
            Blog
          </Link>
        </div>
      </div>
      <div className="flex items-center gap-2">
        {isAuthenticated && profile?.username && (
          <span className="text-xs text-[#8892a4] mr-1">@{profile.username}</span>
        )}
        {!isAuthenticated && (
          <div className="[&_button]:!py-1.5 [&_button]:!px-3 [&_button]:!text-xs [&_button]:!rounded-lg">
            <SignInButton />
          </div>
        )}
        <ConnectButton />
      </div>
    </nav>
  );
}
