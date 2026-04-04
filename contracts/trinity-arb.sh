#!/bin/bash
# Trinity Arb Bot — monitors three pools, arbs when spread exceeds threshold
#
# Usage:
#   ./script/trinity-arb.sh              # check only
#   EXECUTE=true ./script/trinity-arb.sh  # execute arb
#
# Requires: cast, curl, python3, .env with PRIVATE_KEY + BASE_RPC_URL

set -e
cd "$(dirname "$0")/.."
source .env

HOOK="0x6EC5c87935E13450f82e24CB4133f9475e574888"
ROUTER="0xb2934f0533E6db5Ea9Cf9B811567bE87645D2720"
TRI="0x048857035823658872c8BcA4c3C943765e081e85"
USDC="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
WETH="0x4200000000000000000000000000000000000006"
CLP="0x8454d062506a27675706148ECDd194E45e44067a"

USDC_ID="0x953d6a6e6f78c06382348b4ca94e64681b33ce0f2be32a3fb9ba7142b15bdde7"
WETH_ID="0xea8864c3e573579bb36a669bbb40e3475aada623572b235c4076a27c593c7af9"
CLP_ID="0x5bd1df4f4ae128756fc0b4bcd62bc04f334038e191136ae4ceba41c7003754e1"

MIN_SPREAD_BPS=250  # 2.5%

# ── Read pool state ─────────────────────────────────────────────────
read_pool() {
  cast call $HOOK "getCurve(bytes32)(uint256,uint256,uint256,uint256,uint256,address,uint8,bool,bool)" $1 --rpc-url $BASE_RPC_URL 2>/dev/null | sed -n '4p' | grep -o '^[0-9]*'
}

USDC_SOLD=$(read_pool $USDC_ID)
WETH_SOLD=$(read_pool $WETH_ID)
CLP_SOLD=$(read_pool $CLP_ID)

# ── Fetch USD prices for quote assets ───────────────────────────────
ETH_PRICE=$(curl -s "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd" | python3 -c "import json,sys; print(json.load(sys.stdin)['ethereum']['usd'])")
CLP_PRICE=$(curl -s "https://api.geckoterminal.com/api/v2/networks/base/tokens/$CLP" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['attributes']['price_usd'] or '0')")

# ── Compute spreads and find arb ────────────────────────────────────
RESULT=$(python3 << PYEOF
import json

WAD = 10**18
usdc_sold, weth_sold, clp_sold = $USDC_SOLD, $WETH_SOLD, $CLP_SOLD
eth_price, clp_price = $ETH_PRICE, $CLP_PRICE

pools = [
    {"name": "USDC", "sold": usdc_sold, "base": 100000000000000, "slope": 49500000,
     "quote_price": 1.0, "quote_dec": 6, "quote": "$USDC",
     "max_trade": "50000000", "asset": "$USDC"},  # $50
    {"name": "WETH", "sold": weth_sold, "base": 48500000000, "slope": 16000,
     "quote_price": eth_price, "quote_dec": 18, "quote": "$WETH",
     "max_trade": "25000000000000000", "asset": "$WETH"},  # 0.025 ETH
    {"name": "CLP",  "sold": clp_sold,  "base": 3889770000000000000000, "slope": 1280000000000000,
     "quote_price": clp_price, "quote_dec": 18, "quote": "CLP",
     "max_trade": "2000000000000000000000000", "asset": "$CLP"},  # 2M CLP
]

for p in pools:
    spot_native = p["base"] + p["slope"] * p["sold"] // WAD
    p["spot_native"] = spot_native
    p["spot_usd"] = (spot_native / WAD) * p["quote_price"]

# Sort by USD price
by_price = sorted(pools, key=lambda p: p["spot_usd"])
cheap = by_price[0]
expensive = by_price[-1]

spread_bps = int((expensive["spot_usd"] - cheap["spot_usd"]) / cheap["spot_usd"] * 10000)

print(f"ETH: \${eth_price}  |  CLP: \${clp_price:.13f}")
print()
for p in pools:
    print(f"  {p['name']:>5}: {p['sold']/WAD:>12,.0f} TRI sold  spot=\${p['spot_usd']:.8f}")
print()
print(f"  Cheap: {cheap['name']}  Expensive: {expensive['name']}  Spread: {spread_bps} bps")

result = {"spread": spread_bps, "cheap": cheap["name"], "expensive": expensive["name"]}

if spread_bps >= $MIN_SPREAD_BPS and expensive["sold"] > 0:
    result["arb"] = True
    result["buy_asset"] = cheap["asset"]
    result["buy_pool"] = cheap["name"]
    result["sell_pool"] = expensive["name"]
    result["buy_amount"] = cheap["max_trade"]
    result["sell_pool_sold"] = str(expensive["sold"])
    # Which quote asset addresses to use
    result["buy_quote"] = {"USDC": "$USDC", "WETH": "$WETH", "CLP": "$CLP"}[cheap["name"]]
    print(f"  >> ARB: buy {cheap['name']}, sell {expensive['name']}")
else:
    result["arb"] = False
    if expensive["sold"] == 0:
        print(f"  >> Expensive pool has 0 sold, can't arb")
    else:
        print(f"  >> Below {$MIN_SPREAD_BPS} bps threshold")

print()
print(f"ARB_JSON={json.dumps(result)}")
PYEOF
)

echo "$RESULT" | grep -v "^ARB_JSON="

# ── Extract arb decision ────────────────────────────────────────────
ARB_JSON=$(echo "$RESULT" | grep "^ARB_JSON=" | sed 's/^ARB_JSON=//')
HAS_ARB=$(echo "$ARB_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('arb', False))")

if [ "$HAS_ARB" != "True" ]; then
  echo "  No arb. Exiting."
  exit 0
fi

if [ "$EXECUTE" != "true" ]; then
  echo "  Set EXECUTE=true to trade."
  exit 0
fi

# ── Execute arb ─────────────────────────────────────────────────────
BUY_POOL=$(echo "$ARB_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['buy_pool'])")
SELL_POOL=$(echo "$ARB_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['sell_pool'])")
BUY_AMOUNT=$(echo "$ARB_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['buy_amount'])")
SELL_POOL_SOLD=$(echo "$ARB_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['sell_pool_sold'])")

# Map pool name to quote asset + pool key args
pool_quote() {
  case $1 in
    USDC) echo "$USDC" ;;
    WETH) echo "$WETH" ;;
    CLP)  echo "$CLP" ;;
  esac
}

BUY_QUOTE=$(pool_quote $BUY_POOL)
SELL_QUOTE=$(pool_quote $SELL_POOL)

# Sort for PoolKey (currency0 < currency1)
make_key() {
  local quote=$1
  if [[ "$(echo $TRI | tr '[:upper:]' '[:lower:]')" < "$(echo $quote | tr '[:upper:]' '[:lower:]')" ]]; then
    echo "$TRI $quote 0 1 $HOOK"
  else
    echo "$quote $TRI 0 1 $HOOK"
  fi
}

BUY_KEY=$(make_key $BUY_QUOTE)
SELL_KEY=$(make_key $SELL_QUOTE)

ARBER=$(cast wallet address --private-key $PRIVATE_KEY 2>/dev/null)
echo "  Arber: $ARBER"

BUY_KEY_TUPLE="($BUY_KEY)"

if [ "$BUY_POOL" = "WETH" ]; then
  # Native ETH path — no approval needed, send value
  echo "  Step 1: Buy TRI from WETH pool with native ETH ($BUY_AMOUNT wei)..."
  cast send --private-key $PRIVATE_KEY --rpc-url $BASE_RPC_URL \
    $ROUTER "buyTriWithETH((address,address,uint24,int24,address),uint256,address)" \
    "$BUY_KEY_TUPLE" 0 $TRI \
    --value $BUY_AMOUNT 2>/dev/null
else
  # ERC20 path — approve then buy
  echo "  Step 1: Approve $BUY_AMOUNT of $BUY_POOL quote to router..."
  cast send --private-key $PRIVATE_KEY --rpc-url $BASE_RPC_URL \
    $BUY_QUOTE "approve(address,uint256)" $ROUTER $BUY_AMOUNT 2>/dev/null

  echo "  Step 2: Buy TRI from $BUY_POOL pool..."
  cast send --private-key $PRIVATE_KEY --rpc-url $BASE_RPC_URL \
    $ROUTER "buyTri((address,address,uint24,int24,address),uint256,uint256,address)" \
    "$BUY_KEY_TUPLE" $BUY_AMOUNT 0 $TRI 2>/dev/null
fi

TRI_BAL=$(cast call $TRI "balanceOf(address)(uint256)" $ARBER --rpc-url $BASE_RPC_URL 2>/dev/null | grep -o '^[0-9]*')
echo "  Got $TRI_BAL TRI ($(python3 -c "print(f'{$TRI_BAL / 10**18:,.0f}')"))"

# Cap sell to what expensive pool can absorb
MAX_SELLABLE=$(python3 -c "print(min($TRI_BAL, int($SELL_POOL_SOLD) * 100 // 99))")
echo "  Step 3: Approve TRI to router..."

cast send --private-key $PRIVATE_KEY --rpc-url $BASE_RPC_URL \
  $TRI "approve(address,uint256)" $ROUTER $MAX_SELLABLE 2>/dev/null

SELL_KEY_TUPLE="($SELL_KEY)"

if [ "$SELL_POOL" = "WETH" ]; then
  echo "  Step 4: Sell $MAX_SELLABLE TRI to WETH pool (receive native ETH)..."
  cast send --private-key $PRIVATE_KEY --rpc-url $BASE_RPC_URL \
    $ROUTER "sellTriForETH((address,address,uint24,int24,address),uint256,uint256,address)" \
    "$SELL_KEY_TUPLE" $MAX_SELLABLE 0 $TRI 2>/dev/null
else
  echo "  Step 4: Sell $MAX_SELLABLE TRI to $SELL_POOL pool..."
  cast send --private-key $PRIVATE_KEY --rpc-url $BASE_RPC_URL \
    $ROUTER "sellTri((address,address,uint24,int24,address),uint256,uint256,address)" \
    "$SELL_KEY_TUPLE" $MAX_SELLABLE 0 $TRI 2>/dev/null
fi

echo "  ARB COMPLETE"
echo ""

# Final state
NEW_TRI=$(cast call $TRI "balanceOf(address)(uint256)" $ARBER --rpc-url $BASE_RPC_URL 2>/dev/null | grep -o '^[0-9]*')
echo "  Remaining TRI: $(python3 -c "print(f'{$NEW_TRI / 10**18:,.2f}')")"
