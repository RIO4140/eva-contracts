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

// src/LiquidityDepthEngine.sol

 // ^0.8.24: verified with 0.8.24 locally; Remix deploys with 0.8.34

/*
 *  LiquidityDepthEngine (engine #2, family A)
 *  ============================================================
 *  Measures the curve reserve depth in USD (1e8):
 *
 *    depthUSD8 = curveReserveETH * lastGoodEthUSD8 / 1e18
 *
 *  Permissionless poke(), deterministic from on-chain data.
 *  Immutable, no admin. Hub passed per-call.
 */
contract LiquidityDepthEngine {
    IEVACore public immutable CORE;
    bytes32 public constant KEY_DEPTH = keccak256("EVA.SIG.LIQ_DEPTH_USD8");
    bytes32 public constant ENGINE_ID = keccak256("EVA.ENGINE.LIQUIDITY_DEPTH");

    uint256 public lastDepthUSD8;
    uint256 public lastUpdate;

    event Poked(uint256 depthUSD8, uint256 ts);

    constructor(address core_) {
        require(core_ != address(0), "zero core");
        CORE = IEVACore(core_);
    }

    function poke(address hub) external {
        uint256 depth = (CORE.curveReserveETH() * CORE.lastGoodEthUSD8()) / 1e18;
        lastDepthUSD8 = depth;
        lastUpdate = block.timestamp;
        IEVAHub(hub).publish(KEY_DEPTH, depth);
        emit Poked(depth, block.timestamp);
    }

    function engineId() external pure returns (bytes32) { return ENGINE_ID; }

    function signal(bytes32 key) external view returns (uint256 value, uint256 updatedAt) {
        if (key == KEY_DEPTH) return (lastDepthUSD8, lastUpdate);
        return (0, 0);
    }
}

