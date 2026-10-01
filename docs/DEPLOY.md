# EVA — Phased Deployment Guide (Remix + MetaMask, Base)

> **Golden rule:** nothing here touches your private key or seed phrase. YOU sign
> every transaction in MetaMask. The assistant never deploys, funds, or moves
> anything — it only prepares, verifies, and computes.

## Phase 0 — Remix setup (do once)

1. Open the Remix link with: **Solidity 0.8.34, Optimizer ON, Runs = 200,
   EVM version = `cancun`** (set explicitly — do NOT leave on "default").
2. Create one workspace and upload ALL files preserving folders:
   `core/`, `satellites/`, `interfaces/` (contracts import each other by
   relative path — `interfaces/IEVACommon.sol` must resolve).
3. Compile each contract. Zero errors / zero warnings expected.
4. Fund the deployer wallet (your MetaMask account) with Base ETH for gas.

## Phase 1 — Core + FounderVesting (atomic pair)

Core and Vesting reference EACH OTHER in their constructors, so they must be
deployed as a pair with **pre-computed addresses** (no guessing):

1. Pick the deployer account `D` (your MetaMask address).
2. Read its current transaction count (nonce) `N`:
   BaseScan → address page → "Transactions" count, or ask the assistant.
3. **Ask the assistant to compute** (send `D` and `N`):
   - `V1 = address(D, N)` — where Vesting WILL land
   - `C1 = address(D, N+1)` — where Core WILL land
4. **Deploy #1:** `EVA_FounderVesting(eva_ = C1, beneficiary_ = <founder wallet>)`
   → must land exactly at `V1`. If it doesn't — STOP, nonce changed.
5. **Deploy #2 (immediately, no other tx from D in between):**
   `EVA_Core(founder_ = <founder wallet>, vesting_ = V1)`
   → must land exactly at `C1`.

**Post-deploy checks (read-only):**
- `C1.totalSupply()` == 21,000,000 EVA
- founder wallet balance == 500,000 EVA (liquid)
- `V1` holds 2,500,000 EVA (vesting: 2M on 3y/1y-cliff + 500k on 1y linear, no cliff)
- `C1.vesting()` == V1, `V1` beneficiary == founder wallet
- Pool constants: `CURVE_POOL` 9.87M · `AVA_MIG_POOL` 2.1M · `EMISSION_POOL` 2.1M ·
  `AIRDROP_POOL` 1.68M · `TREASURY_POOL` 1.25M · `ECOSYSTEM_POOL` 1M
- `C1.balanceOf(C1)` == 18,000,000 EVA

## Phase 2 — Engines (any order, all immutable)

| Contract | Constructor arg |
|---|---|
| `EVA_LockVault` | `eva_ = C1` |
| `VolatilitySurfaceEngine` | `core_ = C1` |
| `LiquidityDepthEngine` | `core_ = C1` |
| `TWAPOracleEngine` | `feed_ = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` (Chainlink ETH/USD Base) |
| `ReserveSolvencyEngine` | `core_ = C1` |
| `FeeAdaptationEngine` | _(none)_ |

Record every deployed address.

> **Ordering note:** each engine's `poke(address hub)` needs the Hub address,
> so poking happens AFTER Phase 3 (Hub deploy), not here. Deploy the engines
> now; poke them once the Hub exists.

## Phase 3 — Engine Hub

Deploy `EVA_EngineHub` with the registration array. In Remix's constructor
input, pass (replace `0xENG...` with real addresses):

```
[
 ["0xebf6722f2c8fb28b84959e0fcf21d0bd94821dc99d3e3ad93e2edd609d5d4e3b","0xLOCKVAULT"],
 ["0x40d25d4a3ad0a15767ccd38280fbd6c7a16e2d18c8c7aed95ea98a3e98bbb090","0xLOCKVAULT"],
 ["0x972af438ef61ddc51e1e73a65d4b7929d784616b301b84504a56452822e1ea70","0xVOLATILITY"],
 ["0xc08ef84bf25469c4b1722576eaca7df1663b338648b4e2dc93286d7223d9eab5","0xDEPTH"],
 ["0x44e18108ab276cb14612beac53ba34f9bba480c182391d30c064d811db5dfa28","0xTWAP"],
 ["0x8effdc5c81aeb8583ca1a61d867a0d97d0d143a95fba208d63c619dc28652a79","0xTWAP"],
 ["0x53ded523836fc728c5ee85597b88a12f865e714ecf7a2f5b55bd9fa81bed2ccc","0xSOLVENCY"],
 ["0x39f6a5bdc07bae5350f7cedebf80e20b82e49198ec48247e4c27e59e7973f2bb","0xFEE"],
 ["0x59b760ad3f59efce2e0b7c6abeafd580bccda5383ce83724d1d37e4cf8022078","0xFEE"]
]
```

Verify after deploy: `hub.engine(<each key>)` returns the expected engine.

**Now poke each engine once** with the Hub address: `poke(<HUB_ADDRESS>)` on
every engine (and `pokeHub(<HUB_ADDRESS>)` on the LockVault). This is
permissionless — anyone can do it. After that, `hub.pokeAll()` works for
routine refreshes.

## Phase 4 — Connect Hub to Core (governance, ~5 days)

There is NO admin shortcut — this is the constitution working as designed:

1. From the founder wallet (500k EVA ≥ 100k propose threshold), call on Core:
   `propose(5, <HUB_ADDRESS>, "Connect Engine Hub")` → note proposal id.
2. `vote(id, true)` (founder's 500k voting power; quorum rules apply).
3. Wait: 3 days voting + 2 days timelock.
4. `execute(id)` → Core's `engineHub` is now set. Engine signals become live
   (still clamped inside immutable bounds; stale/dead hub = graceful fallback).

**How quorum works (read this):** quorum = 4% of *votable* supply, frozen at
proposal creation. Votable = totalSupply − Core's own pools − vesting lock.
At launch, votable ≈ 500k (just the founder's liquid), so quorum ≈ 20k and
the founder can run this ceremony alone. As EVA circulates (buys, migration,
vested releases), votable grows and the founder's unilateral control decays —
by design. Mid-vote burns can never shrink a proposal's frozen quorum.

**Community spends:** `proposeSpend(pool, to, amount, desc)` —
pool 1 = airdrop (1.68M) · pool 2 = treasury (1.25M) · pool 3 = ecosystem (1M).
Same 3d vote + 2d timelock; caps enforced at propose AND execute time.

## Phase 5 — Funding & activation (your explicit financial approval needed)

- **Seed the curve reserve:** `fundReserve()` on Core with your chosen ETH amount.
  Without this, the first sells have no depth — do NOT claim a deep market
  until this is funded.
- **(Optional) LockVault bonus pool:** transfer EVA to the vault + call
  `notifyRewardEVA(amount)`; send ETH + call `notifyRewardETH()`.
- **Keepers:** anyone can `poke()` the engines; set up your keeper cadence
  (volatility/depth/twap ~hourly, solvency/fee ~daily is plenty).

## If anything looks wrong

STOP. Do not "fix forward" with extra transactions. Send the assistant:
contract address + BaseScan tx link + what you expected vs what happened.
