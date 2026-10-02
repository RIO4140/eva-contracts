#!/usr/bin/env bash
# ============================================================================
# EWA batch4-ewa — ARBITRATION (DEFERRED - nothing to deploy)
# ============================================================================
set -euo pipefail
echo "batch4 (VerifyJury + ThreatMarket) is DEFERRED - nothing to deploy."
echo "Blocked on founder decisions:"
echo "  - EVA_VerifyJury: window, minVoters, maxVoters, whaleCapBps, reporterBps, minStake"
echo "  - EVA_ThreatMarket: needs the VerifyJury address (depends on the above)"
echo "Decide the jury params and this batch will be generated."
