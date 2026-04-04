# Trinity

Three bonding curves. One token. Every sell burns.

Trinity is a bonding curve protocol on Base, implemented as a **Uniswap V4 hook**. A single hook contract serves three independent liquidity pools (USDC, WETH, $CHAOSLP), each with its own pricing curve. Swaps route through V4's PoolManager, making them natively visible to aggregators, bots, and block explorers.

**Live**: [trinity-prototype.pages.dev](https://trinity-prototype.pages.dev)

## How it works

- **Buy** TRI with USDC, ETH, or $CHAOSLP. 1% fee goes to the multisig.
- **Sell** TRI back for any quote asset. 1% of TRI is burned permanently.
- **Arb** between pools. The USDC pool has a steeper slope (1.5x), making TRI more expensive there. Arbers buy cheap on ETH/$CHAOSLP and sell expensive on USDC, converging prices and generating fees + burns.
- **Stake** TRI to earn WETH and $CHAOSLP from pool fees.

The WETH pool accepts native ETH directly -- the router wraps/unwraps automatically.

## Contracts (Base Mainnet)

All contracts are verified on Basescan. Source in [`/contracts`](./contracts/).

| Contract | Address |
|----------|---------|
| TRI Token | [`0x048857035823658872c8BcA4c3C943765e081e85`](https://basescan.org/address/0x048857035823658872c8BcA4c3C943765e081e85) |
| TrinityHook | [`0x6EC5c87935E13450f82e24CB4133f9475e574888`](https://basescan.org/address/0x6EC5c87935E13450f82e24CB4133f9475e574888) |
| TrinityRouter | [`0xb2934f0533E6db5Ea9Cf9B811567bE87645D2720`](https://basescan.org/address/0xb2934f0533E6db5Ea9Cf9B811567bE87645D2720) |
| Staking Hub | [`0x8C507fc36b3e787F0AcC31a82e9829b0ABA28361`](https://basescan.org/address/0x8C507fc36b3e787F0AcC31a82e9829b0ABA28361) |
| WETH Gauge | [`0xF11F22C89Db3fc8E377A7432A28a56C939529f64`](https://basescan.org/address/0xF11F22C89Db3fc8E377A7432A28a56C939529f64) |

## Curve Parameters

| Pool | Supply | Slope | Terminal Price | Cost to Fill |
|------|--------|-------|---------------|-------------|
| TRI/USDC | 334M | 4.95e-11 (1.5x) | $0.01663 | $2,794,400 |
| TRI/WETH | 333M | 3.3e-11 (1x) | $0.01109 | $1,863,000 |
| TRI/$CHAOSLP | 233M | 3.3e-11 (1x) | $0.00779 | $919,100 |

All pools start at ~$0.0001/TRI. Price increases linearly as supply is purchased.

## Development

```bash
npm install
npm run dev
```

Deploys to Cloudflare Pages via `wrangler pages deploy out`.

## Architecture

- **Frontend**: Next.js 16, wagmi, viem, RainbowKit (Base chain)
- **Hook**: Uniswap V4 `beforeSwap` override -- replaces AMM with linear bonding curve math
- **Router**: Pre-settle pattern (settles user input to PoolManager before swap) + ETH wrapping
- **Staking**: ChaosLPHub + RewardGauge pattern (stake TRI, earn WETH + $CHAOSLP)
