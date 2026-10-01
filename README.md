# EVA Contracts — Base Mainnet

Sovereign token system on Base. All contracts are **flat, single-file** — open any `.sol` in [Remix](https://remix.ethereum.org) and compile directly.

## Compiler settings (must match for verification)

- Solidity: `0.8.34`
- Optimizer: enabled, `200` runs
- EVM version: `cancun`

## Contracts

| File | Contract | Address |
|---|---|---|
| `EVA_Core.sol` | EVACore | `0x0A834888B15d249f55498Dd16ac8a64B8c258396` |
| `EVA_FounderVesting.sol` | EVAFounderVesting | `0x5247Ca840cc570daAd69a02Aeb90C011Ab1D1A43` |
| `EVA_EngineHub.sol` | EVAEngineHub | _(deploys after engines)_ |
| `EVA_LockVault.sol` | EVALockVault | _(deploys after engines)_ |
| `VolatilitySurfaceEngine.sol` | VolatilitySurfaceEngine | _(deploys after engines)_ |
| `LiquidityDepthEngine.sol` | LiquidityDepthEngine | _(deploys after engines)_ |
| `TWAPOracleEngine.sol` | TWAPOracleEngine | _(deploys after engines)_ |
| `ReserveSolvencyEngine.sol` | ReserveSolvencyEngine | _(deploys after engines)_ |
| `FeeAdaptationEngine.sol` | FeeAdaptationEngine | _(deploys after engines)_ |

## Token facts

- Total supply: `21,000,000 EVA`
- Founder liquid: `500,000 EVA`
- Founder vesting: `2,500,000 EVA` (2M over 3y/1y-cliff + 500k over 1y linear)
- Core holds `18,000,000 EVA` for curve, migration, staking, airdrop, treasury, ecosystem
- Bonding-curve market, no DEX pool, no admin keys

## Docs

- `docs/DEPLOY.md` — deployment runbook (nonces, constructor args, hub wiring)
- `docs/ENGINES_25.md` — the frozen 25-engine list

## Deployments

- `deployments/base-mainnet.json` — addresses, tx hashes, blocks, constructor args

## Security

No owner, no admin, no upgrade keys. Governance quorum is 4% of votable supply.
