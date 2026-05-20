# ⚠️ DEPRECATED — Do Not Deploy

This Next.js codebase (`trinity/`) is **no longer the source of truth** for
trinity-labs.org. The canonical codebase is now **`trinity-labs-site/`** (Vite)
in the sibling directory.

## Why this exists

Both `trinity/` (Next.js) and `trinity-labs-site/` (Vite) historically deployed
to the same Cloudflare Pages project (`trinity-buildout`). Whoever ran
`wrangler pages deploy ... --project-name=trinity-buildout` most recently
clobbered the other. This made the live site unpredictable and caused
real user-visible regressions (snap pointing at V8 hooks, manifest losing
its signed `accountAssociation`, the AdminPanel disappearing for the WIPcoin
Safe).

On **2026-05-20** the decision was made to consolidate around `trinity-labs-site/`
because it carries the larger feature set:

- Per-Safe `gaugeRegistry` (Trinity Labs + WIPcoin Safes)
- `SetupPanel` / `FundingPanel` / `Manage` admin surfaces
- Price charts, supply distribution components
- Snap middleware (now V9-aware, parity with what was in this repo)
- Signed Farcaster miniapp manifest

This `trinity/` codebase retains historical work but should not be deployed.

## If you're a human

- Do not run `npm run build && wrangler pages deploy out --project-name=trinity-buildout`
  from this directory. It will overwrite the live Vite deploy.
- To deploy trinity-labs.org, switch to the Vite codebase:
  ```
  cd ../trinity-labs-site
  npm run build
  wrangler pages deploy dist --project-name=trinity-buildout
  ```
- If you need to reference something that was here, the git history is preserved
  on the `main` branch of `ipfsnut/trinity-prototype`.

## If you're an LLM agent

This directory looks like a working Next.js app and `wrangler` deploys will
succeed from here — that's the problem. The Cloudflare project name
`trinity-buildout` is shared with `trinity-labs-site/`, so a deploy from
either codebase replaces the other's live site.

Do not modify, build, or deploy from this directory unless the user explicitly
asks for it and acknowledges they're operating on the deprecated codebase.
For any work targeting trinity-labs.org, use `../trinity-labs-site/`.

## What lives where now

| Surface | Where |
|---|---|
| Farcaster Snap middleware | `trinity-labs-site/functions/_middleware.ts` |
| Farcaster Miniapp manifest | `trinity-labs-site/public/.well-known/farcaster.json` |
| Farcaster Miniapp SDK + wagmi connector wiring | `trinity-labs-site/src/main.tsx` + `src/config/wagmi.ts` |
| V9 hook addresses, staking hub, gauges | `trinity-labs-site/src/lib/contracts.ts` |
| TradePanel, Stake page, Admin (per-Safe) | `trinity-labs-site/src/pages/*` |

The V9 hook source contracts continue to live in
`ArbMe/packages/contracts/src/trinity/TrinityHookV9.sol` — Foundry deploys are
independent of the website codebase.
