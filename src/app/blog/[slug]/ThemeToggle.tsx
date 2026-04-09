"use client";

import { useState, type ReactNode } from "react";

export function ThemeToggle({ children }: { children: ReactNode }) {
  const [paper, setPaper] = useState(false);

  return (
    <div
      className={`min-h-screen transition-colors duration-300 ${
        paper ? "bg-[#f4f1ea]" : "bg-black"
      }`}
    >
      <main
        className={`min-h-screen max-w-4xl mx-auto px-6 py-16 transition-colors duration-300 border-x ${
          paper
            ? "bg-[#faf8f4] text-[#2a2a2a] border-[#d4c9b8]"
            : "bg-[#080808] text-[#00ff41] border-[#00ff41]/10"
        }`}
        style={{ fontFamily: "'Times New Roman', 'Georgia', 'Noto Serif', serif" }}
      >
        <button
          onClick={() => setPaper(!paper)}
          className={`fixed top-4 right-4 z-50 px-3 py-1.5 rounded-sm text-xs tracking-wider uppercase border transition-colors font-mono ${
            paper
              ? "bg-[#2a2a2a] text-[#f4f1ea] border-[#2a2a2a] hover:bg-[#444]"
              : "bg-black text-[#00ff41] border-[#00ff41]/40 hover:bg-[#00ff41]/10"
          }`}
        >
          {paper ? "Terminal" : "Paper"}
        </button>
        {children}
      </main>
    </div>
  );
}
