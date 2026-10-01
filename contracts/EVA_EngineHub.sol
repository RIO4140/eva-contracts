// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// src/EVA_EngineHub.sol

/*
 *  EVA Engine Hub — executable registry & signal store
 *  ============================================================
 *  An immutable router between EVA Core and its advisory math engines.
 *
 *  SAFETY MODEL (why this contract can be immutable & adminless):
 *  1. Advisory-only: engines never mint, burn, pause, drain or redirect.
 *     The core clamps every signal to IMMUTABLE [min,max] bounds and
 *     ignores stale (>1 day) or reverting signals via try/catch.
 *  2. No admin keys: registration happens ONCE in the constructor.
 *     Upgrading an engine = deploy a new Hub + timelocked EVA Core
 *     governance proposal (param 5) pointing the core at the new Hub.
 *     There is nothing to steal here, so there is no one to bribe.
 *  3. Push model: registered engines (or their keepers) publish
 *     (value, updatedAt=block.timestamp) via publish(). Core reads are
 *     2 SLOADs — cheap on the buy/sell hot path.
 *  4. One writer per key: only the engine registered for a key may
 *     publish for it. A key with no engine (or zero value + zero
 *     timestamp) is read as "no signal" by the core.
 *
 *  Implements IEVAEngineHub from ../interfaces/IEVAEngine.sol.
 */
contract EVA_EngineHub {
    // ----------------------------------------------------------------
    // Types
    // ----------------------------------------------------------------
    struct Registration { bytes32 key; address engine; }
    struct Signal { uint256 value; uint256 updatedAt; }

    // ----------------------------------------------------------------
    // Storage
    // ----------------------------------------------------------------
    /// @notice key => authorized publisher (the engine contract)
    mapping(bytes32 => address) public engineOf;
    /// @notice key => latest published signal
    mapping(bytes32 => Signal)  public signals;
    /// @notice number of registered keys (informational)
    uint256 public immutable registeredCount;

    // ----------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------
    event EngineRegistered(bytes32 indexed key, address indexed engine);
    event SignalPublished(bytes32 indexed key, uint256 value, uint256 updatedAt);

    // ----------------------------------------------------------------
    // Constructor — one-shot registration, then immutable
    // ----------------------------------------------------------------
    error ZeroEngine(bytes32 key);
    error DuplicateKey(bytes32 key);

    constructor(Registration[] memory regs) {
        uint256 n = regs.length;
        for (uint256 i = 0; i < n; ++i) {
            bytes32 k = regs[i].key;
            address e = regs[i].engine;
            if (e == address(0)) revert ZeroEngine(k);
            if (engineOf[k] != address(0)) revert DuplicateKey(k);
            engineOf[k] = e;
            emit EngineRegistered(k, e);
        }
        registeredCount = n;
    }

    // ----------------------------------------------------------------
    // Publishing — only the registered engine for a key
    // ----------------------------------------------------------------
    error NotEngineForKey(bytes32 key);

    /// @notice Publish a signal for `key`. Only the registered engine.
    /// @dev updatedAt is ALWAYS block.timestamp — engines cannot lie
    ///      about freshness; the core additionally enforces max age.
    function publish(bytes32 key, uint256 value) external {
        if (msg.sender != engineOf[key]) revert NotEngineForKey(key);
        signals[key] = Signal({ value: value, updatedAt: block.timestamp });
        emit SignalPublished(key, value, block.timestamp);
    }

    // ----------------------------------------------------------------
    // Reading — IEVAEngineHub interface
    // ----------------------------------------------------------------
    error UnknownKey(bytes32 key);

    /// @notice Read an advisory signal. Reverts on unknown key so the
    ///         core's try/catch degrades to "no signal" gracefully.
    /// @return value     latest published value (0 = no data)
    /// @return updatedAt block.timestamp of publication (0 = no data)
    function signal(bytes32 key) external view returns (uint256 value, uint256 updatedAt) {
        if (engineOf[key] == address(0)) revert UnknownKey(key);
        Signal memory s = signals[key];
        return (s.value, s.updatedAt);
    }
}

