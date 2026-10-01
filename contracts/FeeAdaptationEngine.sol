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

// src/FeeAdaptationEngine.sol

 // ^0.8.24: verified with 0.8.24 locally; Remix deploys with 0.8.34

/*
 *  FeeAdaptationEngine (engine #5, family C)
 *  ============================================================
 *  Adaptive buy/sell taxes from volatility + solvency signals.
 *
 *    buyTaxBp  = clamp(BUY_BASE  + volBump + solvBump, 50, 500)
 *    sellTaxBp = clamp(SELL_BASE + volBump + solvBump, 100, 800)
 *
 *  where volBump  = min(300, VOL_WAD * 300 / VOL_CAP)   (VOL_CAP = 1e18)
 *        solvBump = solvency < 1e18 ? 100 : 0           (defense)
 *
 *  Reads VOL_WAD / SOLVENCY_WAD from the hub with try/catch: a stale,
 *  dead, or malicious hub degrades to safe defaults (100/150) instead
 *  of reverting. The CORE re-clamps every value anyway (defense in
 *  depth): engine output can never escape the immutable bounds.
 *
 *  Permissionless poke(), immutable, no admin. Hub passed per-call.
 */
contract FeeAdaptationEngine {
    bytes32 public constant KEY_BUY  = keccak256("EVA.SIG.BUY_TAX_BP");
    bytes32 public constant KEY_SELL = keccak256("EVA.SIG.SELL_TAX_BP");
    bytes32 public constant KEY_VOL  = keccak256("EVA.SIG.VOL_WAD");
    bytes32 public constant KEY_SOLV = keccak256("EVA.SIG.SOLVENCY_WAD");
    bytes32 public constant ENGINE_ID = keccak256("EVA.ENGINE.FEE_ADAPTATION");

    uint256 public constant BUY_BASE  = 100; // 1.00%
    uint256 public constant SELL_BASE = 150; // 1.50%
    uint256 public constant VOL_CAP_WAD = 1e18;
    uint256 public constant MAX_VOL_BUMP = 300;
    uint256 public constant SOLV_BUMP = 100;
    uint256 public constant BUY_MIN = 50;
    uint256 public constant BUY_MAX = 500;
    uint256 public constant SELL_MIN = 100;
    uint256 public constant SELL_MAX = 800;
    uint256 public constant SIGNAL_MAX_AGE = 1 days;

    uint256 public lastBuyBp;
    uint256 public lastSellBp;
    uint256 public lastUpdate;

    event Poked(uint256 buyBp, uint256 sellBp, uint256 volWad, uint256 solvWad, uint256 ts);

    /// @notice Permissionless: adapt taxes from hub signals, publish back.
    function poke(address hub) external {
        (uint256 vol, bool volOk) = _freshSignal(hub, KEY_VOL);
        (uint256 solv, bool solvOk) = _freshSignal(hub, KEY_SOLV);

        uint256 volBump = volOk ? (vol > VOL_CAP_WAD ? MAX_VOL_BUMP : (vol * MAX_VOL_BUMP) / VOL_CAP_WAD) : 0;
        uint256 solvBump = (solvOk && solv < 1e18) ? SOLV_BUMP : 0;

        uint256 buy = _clamp(BUY_BASE + volBump + solvBump, BUY_MIN, BUY_MAX);
        uint256 sell = _clamp(SELL_BASE + volBump + solvBump, SELL_MIN, SELL_MAX);

        lastBuyBp = buy;
        lastSellBp = sell;
        lastUpdate = block.timestamp;

        IEVAHub(hub).publish(KEY_BUY, buy);
        IEVAHub(hub).publish(KEY_SELL, sell);
        emit Poked(buy, sell, vol, solv, block.timestamp);
    }

    function _freshSignal(address hub, bytes32 key) internal view returns (uint256 v, bool ok) {
        try IEVAHub(hub).signal(key) returns (uint256 value, uint256 updatedAt) {
            if (updatedAt != 0 && block.timestamp - updatedAt <= SIGNAL_MAX_AGE) {
                return (value, true);
            }
        } catch {}
        return (0, false);
    }

    function _clamp(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (x < lo) return lo;
        if (x > hi) return hi;
        return x;
    }

    function engineId() external pure returns (bytes32) { return ENGINE_ID; }

    function signal(bytes32 key) external view returns (uint256 value, uint256 updatedAt) {
        if (key == KEY_BUY) return (lastBuyBp, lastUpdate);
        if (key == KEY_SELL) return (lastSellBp, lastUpdate);
        return (0, 0);
    }
}

