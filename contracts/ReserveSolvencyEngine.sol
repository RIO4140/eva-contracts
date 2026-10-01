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

// src/ReserveSolvencyEngine.sol

 // ^0.8.24: verified with 0.8.24 locally; Remix deploys with 0.8.34

/*
 *  ReserveSolvencyEngine (engine #4, family B)
 *  ============================================================
 *  Reserve health vs CONSERVATIVE spot liability (everyone sells at
 *  the current spot price — an overestimate of true integral
 *  liability, so the ratio is a lower bound on real solvency):
 *
 *    spotLiabETH = sold * spotPriceUSD8 / lastGoodEthUSD8   (wei)
 *    solvency    = curveReserveETH * 1e18 / spotLiabETH      (wad)
 *
 *  >= 1e18 means the reserve covers even a full spot-price bank run.
 *  Publishes SOLVENCY_WAD. Permissionless poke(), deterministic,
 *  immutable, no admin. Hub passed per-call.
 */
contract ReserveSolvencyEngine {
    IEVACore public immutable CORE;
    bytes32 public constant KEY_SOLVENCY = keccak256("EVA.SIG.SOLVENCY_WAD");
    bytes32 public constant ENGINE_ID = keccak256("EVA.ENGINE.RESERVE_SOLVENCY");

    uint256 public lastSolvencyWad;
    uint256 public lastUpdate;

    event Poked(uint256 solvencyWad, uint256 ts);

    constructor(address core_) {
        require(core_ != address(0), "zero core");
        CORE = IEVACore(core_);
    }

    function poke(address hub) external {
        uint256 sold = CORE.sold();
        uint256 solv;
        if (sold == 0) {
            solv = type(uint256).max; // no liability yet: perfectly solvent
        } else {
            uint256 spot = CORE.spotPriceUSD8();          // USD8
            uint256 ethUsd = CORE.lastGoodEthUSD8();      // USD8
            // spotLiabETH(wei) = sold(wei) * spot(USD8) / ethUsd(USD8)
            uint256 liab = (sold * spot) / ethUsd;
            uint256 reserve = CORE.curveReserveETH();
            solv = liab == 0 ? type(uint256).max : (reserve * 1e18) / liab;
        }
        lastSolvencyWad = solv;
        lastUpdate = block.timestamp;
        IEVAHub(hub).publish(KEY_SOLVENCY, solv);
        emit Poked(solv, block.timestamp);
    }

    function engineId() external pure returns (bytes32) { return ENGINE_ID; }

    function signal(bytes32 key) external view returns (uint256 value, uint256 updatedAt) {
        if (key == KEY_SOLVENCY) return (lastSolvencyWad, lastUpdate);
        return (0, 0);
    }
}

