// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// src/EVA_FounderVesting.sol

 // ^0.8.24: verified with 0.8.24 locally; Remix deploys with 0.8.34

/*
 *  EVA Founder Vesting — "EVAFounderVesting"
 *  ============================================================
 *  Holds 2,500,000 EVA for the founder in TWO immutable tranches:
 *
 *    Tranche A (long):  2,000,000 EVA — 1-year cliff, then linear to year 3.
 *    Tranche B (short):   500,000 EVA — linear over 1 year, NO cliff
 *                         (vests from day 0).
 *
 *  Release is permissionless — ANYONE can trigger it — but only the
 *  founder (immutable beneficiary) ever receives. No owner, no roles,
 *  no revocation, no acceleration. The schedule is the law.
 */

interface IEVA {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract EVAFounderVesting {
    IEVA public immutable EVA;
    address public immutable BENEFICIARY;
    uint64 public immutable START;

    // Tranche A: 2M, 1-year cliff, 3-year total.
    uint64 public immutable CLIFF_A = 365 days;
    uint64 public immutable DURATION_A = 3 * 365 days;
    uint256 public immutable TOTAL_A = 2_000_000 * 1e18;

    // Tranche B: 500k, linear over 1 year, no cliff.
    uint64 public immutable DURATION_B = 365 days;
    uint256 public immutable TOTAL_B = 500_000 * 1e18;

    uint256 public constant TOTAL = 2_500_000 * 1e18;

    uint256 public released;

    event VestingReleased(address indexed to, uint256 amount);

    constructor(address eva_, address beneficiary_) {
        require(eva_ != address(0) && beneficiary_ != address(0), "zero address");
        EVA = IEVA(eva_);
        BENEFICIARY = beneficiary_;
        START = uint64(block.timestamp);
    }

    /// @notice Tranche A vested so far (linear after cliff, all after duration).
    function vestedA() public view returns (uint256) {
        uint64 nowTs = uint64(block.timestamp);
        if (nowTs < START + CLIFF_A) return 0;
        if (nowTs >= START + DURATION_A) return TOTAL_A;
        return (TOTAL_A * (nowTs - START)) / DURATION_A;
    }

    /// @notice Tranche B vested so far (linear from day 0, no cliff).
    function vestedB() public view returns (uint256) {
        uint64 nowTs = uint64(block.timestamp);
        if (nowTs >= START + DURATION_B) return TOTAL_B;
        return (TOTAL_B * (nowTs - START)) / DURATION_B;
    }

    /// @notice Total EVA vested so far across both tranches.
    function vested() public view returns (uint256) {
        return vestedA() + vestedB();
    }

    /// @notice Releasable right now (vested minus already released).
    function releasable() public view returns (uint256) {
        uint256 v = vested();
        return v > released ? v - released : 0;
    }

    /// @notice Release vested EVA to the founder. Anyone may call.
    function release() external {
        uint256 amt = releasable();
        require(amt > 0, "nothing to release");
        released += amt;
        bool ok = EVA.transfer(BENEFICIARY, amt);
        require(ok, "transfer failed");
        emit VestingReleased(BENEFICIARY, amt);
    }
}

