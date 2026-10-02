#!/bin/bash
# EVA satellites — batch 1 (11 contracts) on Base mainnet
# Run:  export PK=0x...   (your deployer key; unset after)
#       bash deploy-batch1.sh
pwd
ls
set -e

RPC="https://mainnet.base.org"
BASE="https://raw.githubusercontent.com/RIO4140/eva-contracts/main/deployments/initcode-batch1-2026-10-02"
CORE="0x0a834888b15d249f55498dd16ac8a64b8c258396"
REGISTRY="0x51a8c2205e51900df394f85184a2a4e0a36ef0cc"
TREASURY="0xf4f33f0e9bde1f52fb365b48b32a230cae1caf72"

command -v cast >/dev/null || { echo "cast not found — install foundry first"; exit 1; }
[ -z "$PK" ] && { echo "PK is not set. export PK=0x... first"; exit 1; }

DEPLOYER=$(cast wallet address --private-key "$PK")
echo "Deployer: $DEPLOYER"
echo "Balance (wei): $(cast balance "$DEPLOYER" --rpc-url "$RPC")"

LOG="deployed_batch1.log"
touch "$LOG"

check() { # check <addr> <sig> <expected> <label>
  local got want
  got=$(cast call "$1" "$2" --rpc-url "$RPC" | tr '[:upper:]' '[:lower:]')
  want=$(echo "$3" | tr '[:upper:]' '[:lower:]')
  if [ "$got" = "$want" ]; then echo "  PASS $4";
  else echo "  FAIL $4 :: got=$got want=$want"; exit 1; fi
}

verify() { # verify <name> <addr>
  case "$1" in
    EVA_VerifyJury)
      check "$2" "REGISTRY()(address)" "$REGISTRY" "REGISTRY"
      check "$2" "WHALE_CAP_BPS()(uint256)" "2000" "WHALE_CAP_BPS"
      check "$2" "MIN_STAKE()(uint256)" "1000000000000000000000" "MIN_STAKE" ;;
    EVA_ResilienceCredits)
      check "$2" "CORE()(address)" "$CORE" "CORE"
      check "$2" "CLAIM_DELAY()(uint64)" "86400" "CLAIM_DELAY"
      check "$2" "TILT_CAP()(uint256)" "300" "TILT_CAP" ;;
    EVA_ReopenAuction)
      check "$2" "CORE()(address)" "$CORE" "CORE"
      check "$2" "MAX_INTENTS()(uint8)" "100" "MAX_INTENTS"
      check "$2" "MIN_BUY_ETH()(uint256)" "10000000000000000" "MIN_BUY_ETH" ;;
    EVA_DelegationDecay)
      check "$2" "CORE()(address)" "$CORE" "CORE"
      check "$2" "MISS_FLOOR()(uint8)" "6" "MISS_FLOOR" ;;
    EVA_CongestionExit)
      check "$2" "EVA()(address)" "$CORE" "EVA"
      check "$2" "BASE_BPS()(uint256)" "200" "BASE_BPS"
      check "$2" "CAP_BPS()(uint256)" "2500" "CAP_BPS" ;;
    EVA_BoostAuction)
      check "$2" "EVA()(address)" "$CORE" "EVA"
      check "$2" "EPOCH_LEN()(uint256)" "604800" "EPOCH_LEN"
      check "$2" "MULT_BPS()(uint256)" "12000" "MULT_BPS" ;;
    EVA_AdaptiveCurve)
      check "$2" "CORE()(address)" "$CORE" "CORE"
      check "$2" "MAX_TRADE_BP()(uint256)" "100" "MAX_TRADE_BP"
      check "$2" "KEEPER_FEE()(uint256)" "1000000000000000000" "KEEPER_FEE" ;;
    EVA_EMADampener)
      check "$2" "CORE()(address)" "$CORE" "CORE"
      check "$2" "ALPHA_BPS()(uint256)" "1000" "ALPHA_BPS"
      check "$2" "KEEPER_FEE()(uint256)" "1000000000000000000" "KEEPER_FEE" ;;
    EVA_PrioritySlot)
      check "$2" "STAKER_VAULT()(address)" "$TREASURY" "STAKER_VAULT"
      check "$2" "TREASURY()(address)" "$TREASURY" "TREASURY" ;;
    EVA_BondedDepth)
      check "$2" "STAKER_VAULT()(address)" "$TREASURY" "STAKER_VAULT"
      check "$2" "REWARD_PER_EVA()(uint256)" "1000000000000000" "REWARD_PER_EVA" ;;
    EVA_TenureVote)
      check "$2" "CORE()(address)" "$CORE" "CORE" ;;
  esac
}

deploy() { # deploy <name>
  local name=$1
  if grep -q "^$name " "$LOG"; then echo "== $name already deployed — skipping"; return; fi
  echo "== deploying $name"
  curl -sL "$BASE/$name.initcode.hex" -o "/tmp/$name.hex"
  [ -s "/tmp/$name.hex" ] || { echo "download failed for $name"; exit 1; }
  local out addr
  out=$(cast send --create "$(cat "/tmp/$name.hex")" --private-key "$PK" --rpc-url "$RPC" --gas-limit 10000000 2>&1)
  echo "$out" | tail -8
  addr=$(echo "$out" | grep -i "contractAddress" | awk '{print $2}')
  [ -z "$addr" ] && { echo "!! could not parse contract address for $name — STOPPING. paste output before re-running."; exit 1; }
  echo "$name $addr" >> "$LOG"
  echo ">> $name deployed at $addr"
  verify "$name" "$addr"
  echo ""
}

# VerifyJury first — batch 2 (ThreatMarket, ResponsePlaybooks) needs its address
for c in EVA_VerifyJury EVA_ResilienceCredits EVA_ReopenAuction EVA_DelegationDecay \
         EVA_CongestionExit EVA_BoostAuction EVA_AdaptiveCurve EVA_EMADampener \
         EVA_PrioritySlot EVA_BondedDepth EVA_TenureVote; do
  deploy "$c"
done

echo "================ BATCH 1 DONE ================"
cat "$LOG"
echo "=============================================="
echo "Copy the VerifyJury address above and send it back."
echo "When finished: unset PK ; history -c"
