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

// src/TWAPOracleEngine.sol

 // ^0.8.24: verified with 0.8.24 locally; Remix deploys with 0.8.34

/*
 *  TWAPOracleEngine (engine #3, family E)
 *  ============================================================
 *  Double-window TWAP of ETH/USD from the Chainlink feed, kept as
 *  cumulative price*time checkpoints (arithmetic v1; geometric is the
 *  documented v2 upgrade path). Windows: FAST = 30 min, SLOW = 4 h.
 *
 *    twap(W) = (cum(now) - cum(now - W)) / W
 *
 *  Permissionless poke() checkpoints the feed. Stale Chainlink data
 *  (updatedAt older than 1 day, or non-positive answer) reverts the
 *  poke instead of publishing garbage.
 *
 *  Immutable, no admin. Hub passed per-call.
 */
contract TWAPOracleEngine {
    IChainlinkFeed public immutable FEED;
    bytes32 public constant KEY_FAST = keccak256("EVA.SIG.TWAP_FAST_USD8");
    bytes32 public constant KEY_SLOW = keccak256("EVA.SIG.TWAP_SLOW_USD8");
    bytes32 public constant ENGINE_ID = keccak256("EVA.ENGINE.TWAP_ORACLE");

    uint256 public constant FAST_WINDOW = 30 minutes;
    uint256 public constant SLOW_WINDOW = 4 hours;
    uint256 public constant STALE_AFTER = 1 days;
    /// @notice Minimum time between pokes. Permissionless poke() must not let
    ///         `history` grow without bound: even a linear prune exceeds block
    ///         gas if thousands of checkpoints accumulate (4h of 2s blocks).
    ///         60s keeps the TWAP fresh (FAST window = 30 min) while capping
    ///         history at SLOW_WINDOW / 60s + 1 = 241 checkpoints.
    uint256 public constant MIN_POKE_INTERVAL = 60;

    struct Checkpoint { uint64 ts; uint256 cum; } // cum = sum(price*dt), USD8*sec
    Checkpoint[] public history;

    uint256 public lastPriceUSD8;
    uint256 public lastUpdate;
    uint256 public lastPoke;

    event Poked(uint256 priceUSD8, uint256 twapFast, uint256 twapSlow, uint256 ts);

    error StaleFeed();
    error BadAnswer();

    constructor(address feed_) {
        require(feed_ != address(0), "zero feed");
        FEED = IChainlinkFeed(feed_);
    }

    /// @notice Checkpoint the feed and publish both TWAPs.
    /// @dev Throttled: pokes sooner than MIN_POKE_INTERVAL after the last one
    ///      revert. Without this, burst poking grows `history` until even the
    ///      linear _prune below exceeds block gas (DoS, audit 2026-10-01).
    function poke(address hub) external {
        require(block.timestamp >= lastPoke + MIN_POKE_INTERVAL, "poke too soon");
        (uint256 price, ) = _readFeed();
        uint64 now_ = uint64(block.timestamp);
        lastPoke = block.timestamp;

        if (history.length == 0) {
            history.push(Checkpoint({ts: now_, cum: 0}));
        } else {
            Checkpoint storage last = history[history.length - 1];
            uint256 dt = block.timestamp - last.ts;
            history.push(Checkpoint({
                ts: now_,
                cum: last.cum + lastPriceUSD8 * dt
            }));
        }
        lastPriceUSD8 = price;
        lastUpdate = block.timestamp;
        _prune(now_);

        (uint256 fast, uint256 slow) = twaps();
        IEVAHub(hub).publish(KEY_FAST, fast);
        IEVAHub(hub).publish(KEY_SLOW, slow);
        emit Poked(price, fast, slow, block.timestamp);
    }

    /// @notice Current double-window TWAPs (0 until the window fills).
    function twaps() public view returns (uint256 fast, uint256 slow) {
        uint256 n = history.length;
        if (n == 0 || lastPriceUSD8 == 0) return (0, 0);
        uint256 cumNow = history[n - 1].cum + lastPriceUSD8 * (block.timestamp - history[n - 1].ts);
        fast = _windowTwap(cumNow, FAST_WINDOW);
        slow = _windowTwap(cumNow, SLOW_WINDOW);
    }

    /// @notice Exact window TWAP via linear interpolation of cum at cutoff.
    function _windowTwap(uint256 cumNow, uint256 window) internal view returns (uint256) {
        uint256 n = history.length;
        // Defensive: on a fresh chain block.timestamp can be < window.
        uint256 cutoff = block.timestamp > window ? block.timestamp - window : 0;
        if (history[0].ts > cutoff) return 0; // window not filled yet
        // Find segment [i, i+1] containing cutoff.
        uint256 i = 0;
        while (i + 1 < n && history[i + 1].ts <= cutoff) i++;
        uint256 cumAtCutoff;
        if (history[i].ts == cutoff) {
            cumAtCutoff = history[i].cum;
        } else {
            // Linear interpolation inside the segment.
            uint256 segDt = history[i + 1].ts - history[i].ts;
            uint256 segDc = history[i + 1].cum - history[i].cum;
            cumAtCutoff = history[i].cum + (segDc * (cutoff - history[i].ts)) / segDt;
        }
        return (cumNow - cumAtCutoff) / window;
    }

    function _prune(uint64 now_) internal {
        // Single-pass compaction: O(n). The previous version popped one
        // checkpoint per while-iteration with a full array shift each time
        // (O(n^2)); a burst of permissionless pokes followed by 4h of aging
        // made the next poke exceed block gas and revert forever on this
        // immutable contract (audit finding 2026-10-01).
        //
        // Semantics preserved: keep one anchor checkpoint at/before
        // (now - SLOW_WINDOW) — the slow window needs a left anchor for exact
        // interpolation — plus everything newer; always keep >= 2 checkpoints.
        uint256 n = history.length;
        if (n <= 2) return;
        uint256 cutoff = now_ >= SLOW_WINDOW ? now_ - SLOW_WINDOW : 0;
        uint256 anchor = 0; // newest checkpoint at/before cutoff
        for (uint256 i = 0; i < n; i++) {
            if (history[i].ts <= cutoff) anchor = i;
            else break;
        }
        uint256 drop = anchor;
        if (n - drop < 2) drop = n - 2;
        if (drop == 0) return;
        for (uint256 i = drop; i < n; i++) {
            history[i - drop] = history[i];
        }
        for (uint256 i = 0; i < drop; i++) {
            history.pop();
        }
    }

    function _readFeed() internal view returns (uint256 priceUSD8, uint256 updatedAt) {
        (, int256 answer, , uint256 ts, ) = FEED.latestRoundData();
        if (answer <= 0) revert BadAnswer();
        if (block.timestamp - ts > STALE_AFTER) revert StaleFeed();
        return (uint256(answer), ts);
    }

    function engineId() external pure returns (bytes32) { return ENGINE_ID; }

    function signal(bytes32 key) external view returns (uint256 value, uint256 updatedAt) {
        (uint256 fast, uint256 slow) = twaps();
        if (key == KEY_FAST) return (fast, lastUpdate);
        if (key == KEY_SLOW) return (slow, lastUpdate);
        return (0, 0);
    }
}

