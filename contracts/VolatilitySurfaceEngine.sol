// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// src/IEVACommon.sol

 // ^0.8.24: verified with 0.8.24 locally; Remix deploys with 0.8.34

/*
 *  EVA Engine Common Interfaces
 *  ============================================================
 *  Shared read-only interfaces for all EVA satellite contracts
 *  (engines + lock vault). Single declaration point: importing this
 *  file avoids "Identifier already declared" collisions when the
 *  satellites are compiled together (Foundry) or in one Remix
 *  workspace.
 */

/// @notice Read-only view of the EVA Core state engines may consume.
interface IEVACore {
    function spotPriceUSD8() external view returns (uint256);
    function curveReserveETH() external view returns (uint256);
    function lastGoodEthUSD8() external view returns (uint256);
    function sold() external view returns (uint256);
}

/// @notice The immutable Engine Hub: engines publish, anyone reads.
interface IEVAHub {
    function publish(bytes32 key, uint256 value) external;
    function signal(bytes32 key) external view returns (uint256 value, uint256 updatedAt);
}

/// @notice Chainlink AggregatorV3 minimal interface.
interface IChainlinkFeed {
    function latestRoundData() external view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Minimal ERC-20 interface for the lock vault.
interface IEVAToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// src/VolatilitySurfaceEngine.sol

 // ^0.8.24: verified with 0.8.24 locally; Remix deploys with 0.8.34

/*
 *  VolatilitySurfaceEngine (engine #1, family A)
 *  ============================================================
 *  EWMA variance estimator of the EVA spot price.
 *
 *  On every permissionless poke():
 *    p  = core.spotPriceUSD8()            (EVA/USD, 1e8)
 *    r  = (p - lastP) / lastP             (simple return, wad)
 *    var = ALPHA * r^2 + (1 - ALPHA) * var   (ALPHA = 0.10)
 *
 *  Publishes VOL_WAD (1e18 = 100% variance). Deterministic from
 *  on-chain data: anyone can poke, nobody can lie. The core clamps
 *  every downstream use; a stale/dead engine degrades to "no signal".
 *
 *  Immutable, no admin, no owner. Hub passed per-call (no circular
 *  constructor dependency).
 */
contract VolatilitySurfaceEngine {
    IEVACore public immutable CORE;
    bytes32 public constant KEY_VOL = keccak256("EVA.SIG.VOL_WAD");
    bytes32 public constant ENGINE_ID = keccak256("EVA.ENGINE.VOLATILITY_SURFACE");

    uint256 public constant ALPHA_WAD = 1e17; // 0.10

    uint256 public lastPriceUSD8;
    uint256 public varWad;          // EWMA variance, 1e18
    uint256 public lastUpdate;

    event Poked(uint256 priceUSD8, uint256 varWad, uint256 ts);

    error NoPrice();

    constructor(address core_) {
        require(core_ != address(0), "zero core");
        CORE = IEVACore(core_);
    }

    /// @notice Permissionless observation + EWMA update + hub publish.
    function poke(address hub) external {
        uint256 p = CORE.spotPriceUSD8();
        if (p == 0) revert NoPrice();
        if (lastPriceUSD8 > 0) {
            uint256 rWad = _absRetWad(p, lastPriceUSD8);
            uint256 r2 = (rWad * rWad) / 1e18;
            varWad = (ALPHA_WAD * r2 + (1e18 - ALPHA_WAD) * varWad) / 1e18;
        }
        lastPriceUSD8 = p;
        lastUpdate = block.timestamp;
        IEVAHub(hub).publish(KEY_VOL, varWad);
        emit Poked(p, varWad, block.timestamp);
    }

    function _absRetWad(uint256 p, uint256 lastP) internal pure returns (uint256) {
        uint256 diff = p > lastP ? p - lastP : lastP - p;
        return (diff * 1e18) / lastP;
    }

    // -- IEVAEngine face -------------------------------------------------
    function engineId() external pure returns (bytes32) { return ENGINE_ID; }

    function signal(bytes32 key) external view returns (uint256 value, uint256 updatedAt) {
        if (key == KEY_VOL) return (varWad, lastUpdate);
        return (0, 0);
    }
}

