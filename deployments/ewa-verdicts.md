# EWA deployment verdicts — 2026-10-02

**EWA_Core:** `0x0201981D7BFE0E79DEACb0B5eae0F83022Cc18eB` (Base mainnet, 21M cap, 3M minted)
**Method per contract:** source review (read-only) → Base mainnet fork test vs real EWA_Core → exact-scope Slither (High/Medium triaged) → Termux deploy snippet (embedded bytecode, post-deploy `cast call` verification).
**Strict rule applied:** any doubt about a contract or parameter = immediate deferral with documented reason. No guessing. Nothing deploys without the founder's signature from Termux.

**Final tally:** 15 ready · 14 deferred · 12 needs-adapter · 5 excluded · 1 per-deal · 1 deployed = **48**

---

## READY (15) — covered by batch1-3 scripts

| Contract | Batch | Fork | Slither H/M | Notes |
|---|---|---|---|---|
| EVA_Multisig | 1 | PASS (submit/confirm/execute, 1-of-1) | 0/0 | owners=[founder], threshold=1 (founder precedent) |
| EVA_Treasury | 1 | PASS (multisig→timelock→execute full lifecycle) | 0/0 | council=$MULTISIG; 2-day timelock by design |
| IncidentRegistry | 1 | PASS (2 independent scenarios, all fields) | 0/0 | no args |
| EVA_Conditional | 1 | PASS (HTLC lock/claim/refund + ERC20 path with real EWA) | 0/0 | no args |
| EVA_Stream | 1 | PASS (stream + claim + cancel, exact conservation) | 0/0 | no args |
| EVA_Subscriptions | 1 | PASS (pull-payment, exact 20 EWA accounting) | 0/0 | no args |
| EVA_TokenFactory | 1 | PASS (token created, metadata exact) | 0/0 | no args |
| EVA_Vesting | 1 | PASS (vesting math exact to the wei) | 0/5 (all FP) | no args |
| EVA_KeeperScheduler | 1 | PASS (register + cooldown/registrar negative paths) | 0/2 (FP/safe) | registrar=founder; cooldown=86400 **(coordinator default — confirm)** |
| EVA_LockVault | 2 | PASS (1000 EWA locked end-to-end, EVA()==EWA_CORE) | 0/0 | token=EWA_CORE |
| EVA_RewardDistributor | 2 | PASS (fund→score→finalize→claim, exact 50% payout) | 0/0 | token=EWA_CORE; epoch=86400 **(default — confirm)**; **direct-transfer trap confirmed: fund ONLY via `fund()`** |
| AdaptiveDefense | 3 | PASS (incident→defense signal, level cap logic) | 0/0 | registry=$INCIDENTREG |
| TWAPOracleEngine | 3 | PASS (live Chainlink ETH/USD, TWAP=$2,663.32 sane) | 0/0 | feed=ETH/USD `0x71041d…b70` (verified) |
| FeeAdaptationEngine | 3 | PASS (fee math 350/400bp exact) | 0/0 | no args; low doc mismatch: dead-hub reverts instead of degrading (not blocking) |
| EVA_EngineHub | 3 | PASS (5 regs, aggregation, negatives) | 0/0 | regs = DEFENSE_LEVEL, TWAP_FAST/SLOW_USD8, BUY/SELL_TAX_BP on 3 live engines |

## DEFERRED (14) — reason documented, not in scripts

| Contract | Blocked on |
|---|---|
| EVAFounderVesting | beneficiary + vesting schedule undecided |
| EVA_BoostAuction | epochLen/k/multBps/minBid economic params undecided |
| EVA_BoundedGovernance | needs governed-module interfaces (code change) |
| EVA_CongestionExit | baseBps/k/capBps/window/minLock/maxLock undecided |
| EVA_DangerScore | **coordinator override:** 12 risk-model weights = founder modeling decision (worker verdict was READY; snippet preserved in /tmp) |
| EVA_FeeAdaptationV2 | needs `omega<=10000` enforced in code |
| EVA_LoyaltyBadge | baseURI + tierMinimums undecided |
| EVA_NFT | no collection concept (pre-existing) |
| EVA_OracleBlend | 2 more verified Chainlink feeds (only ETH/USD on record) |
| EVA_SortitionPanel | VRF (vrf/keyHash/subId) |
| EVA_Splitter | payees/shares undecided |
| EVA_ThreatMarket | depends on VerifyJury |
| EVA_USDThresholds | priceFeed + confidenceSource |
| EVA_VerifyJury | window/minVoters/maxVoters/whaleCapBps/reporterBps/minStake undecided |

## NEEDS-ADAPTER (12)

**Governance-dependent (5):** DelegationDecay, StreakAttest, TenureVote, MACIVote, ResponsePlaybooks — need GovernanceSatellite (`vote/propose/hasVoted/votingPowerOf`).
**Market-dependent (4):** AdaptiveCurve, EMADampener, PrioritySlot, BondedDepth — need MarketSatellite (`buy/sell/previews`).
**Dead on EWA_Core (3, fork-proven):** LiquidityDepthEngine, ReserveSolvencyEngine, VolatilitySurfaceEngine — call `sold()/spotPriceUSD8()/curveReserveETH()/lastGoodEthUSD8()`, none exist on the minimal core; `poke()` reverts permanently. Need rebinding to new data sources. **Excluded from EngineHub regs.**

## EXCLUDED (5) / PER-DEAL (1) / DEPLOYED (1)

- Excluded: EVA_ReopenAuction (tied to dead breaker), EVA_ResilienceCredits (tied to breaker incidents), EVA_Core (old, breaker bug), EVA_EduInherit (out of token scope), EVA_SimpleToken (TokenFactory covers it)
- Per-deal: EVA_Escrow (deploy per deal only)
- Deployed: EWA_Core `0x0201981D7BFE0E79DEACb0B5eae0F83022Cc18eB`

---

## Founder confirmation required (in-script CONFIRM_DEFAULTS gate)

Each batch script refuses to run until `CONFIRM_DEFAULTS=yes` is exported after reviewing:
1. Multisig 1-of-1 founder (precedent) — batch1
2. KeeperScheduler cooldown=86400 — batch1
3. RewardDistributor epoch=86400 — batch2 (also: fund ONLY via `fund()`)
4. EngineHub 5-reg layout on 3 live engines — batch3

## Blocked params needing founder decisions (exact)

- **EVAFounderVesting:** beneficiary address + vesting schedule (cliff/duration)
- **EVA_BoostAuction:** epochLen, k, multBps, minBid
- **EVA_CongestionExit:** baseBps, k, capBps, window, minLock, maxLock
- **EVA_LoyaltyBadge:** minter, baseURI, tierMinimums[4]
- **EVA_Splitter:** payees[], shares[]
- **EVA_VerifyJury:** window, minVoters, maxVoters, whaleCapBps, reporterBps, minStake
- **EVA_DangerScore:** 12 indicator weights (see worker's per-indicator table in handoff)
- **External addresses:** VRF (vrf/keyHash/subId), EAS (StreakAttest adapter), MACI verifier (MACIVote adapter), 2 more Chainlink feeds (OracleBlend/USDThresholds)
- **Code changes (not done — read-only mandate):** FeeAdaptationV2 `omega<=10000`, BoundedGovernance interfaces, adapter designs for the 12 needs-adapter
