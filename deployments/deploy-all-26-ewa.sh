#!/usr/bin/env bash
# ============================================================================
# EWA FULL DEPLOYMENT — all 26 ready contracts in one run
# Runs batch1 -> batch2 -> batch3 -> batch4 in order, ~5s between contracts
# (each batch already sleeps 5s between transactions; extra 5s between batches).
#
# RUN (Termux) — copy/paste:
#   cd ~/eva-contracts && git pull
#   export PK=0x...                 # founder signer key (never paste in chat)
#   export CONFIRM_DEFAULTS=yes     # ONLY after reviewing deployments/ewa-params.md
#   bash deployments/deploy-all-26-ewa.sh
#   unset PK && history -c
#
# Founder signs every transaction. Nothing deploys without his key.
# ============================================================================
set -euo pipefail

: "${PK:?export PK=0x... first (founder signer key)}"
if [ "${CONFIRM_DEFAULTS:-}" != "yes" ]; then
  echo "ABORT: review deployments/ewa-params.md first, then export CONFIRM_DEFAULTS=yes"
  exit 1
fi

D="$(cd "$(dirname "$0")" && pwd)"
export RPC="${RPC:-https://mainnet.base.org}"

echo "=================================================================="
echo "EWA FULL DEPLOYMENT — 26 contracts"
echo "rpc: $RPC"
echo "deployer: $(cast wallet address --private-key "$PK")"
echo "=================================================================="
echo ""

run_batch() {
  echo ""
  echo "##################################################################"
  echo "# $1"
  echo "##################################################################"
  bash "$D/$2"
  echo ""
  echo "--- 5s pause before next batch ---"
  sleep 5
}

run_batch "BATCH 1/4 — foundation (11 contracts)" "batch1-ewa.sh"
run_batch "BATCH 2/4 — core-connected (7 contracts)" "batch2-ewa.sh"
run_batch "BATCH 3/4 — defense (6 contracts)" "batch3-ewa.sh"
run_batch "BATCH 4/4 — arbitration (2 contracts)" "batch4-ewa.sh"

echo ""
echo "=================================================================="
echo "ALL 26 CONTRACTS DEPLOYED — address record:"
echo "=================================================================="
cat "$D/ewa-addresses.env" 2>/dev/null || echo "(no address file found)"
echo "=================================================================="
echo "Next: verify each address on BaseScan, then wire satellites."
