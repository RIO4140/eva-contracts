// SPDX-License-Identifier: MIT
pragma solidity 0.8.34; // pinned: audited, tested and deployed with solc 0.8.34

/*
 *  EVA Founder Vesting — "EVAFounderVesting"
 *  ============================================================
 *  Holds founder EWA in TWO immutable tranches whose schedule is fixed
 *  explicitly at construction:
 *
 *    Tranche A: totalA_ — cliffA_ cliff, then linear to durationA_.
 *    Tranche B: totalB_ — linear over durationB_, no cliff.
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

    // Tranche A: amount, cliff, and total duration (all set at deploy).
    uint64 public immutable CLIFF_A;
    uint64 public immutable DURATION_A;
    uint256 public immutable TOTAL_A;

    // Tranche B: amount and duration (linear from day 0, no cliff).
    uint64 public immutable DURATION_B;
    uint256 public immutable TOTAL_B;

    uint256 public immutable TOTAL;

    uint256 public released;

    event VestingReleased(address indexed to, uint256 amount);

    /// @notice Deploys the vesting vault with an explicit schedule.
    /// @param eva_ EWA_Core address. Must be non-zero. Uses only
    ///        transfer/balanceOf, both supported by EWA_Core.
    /// @param beneficiary_ Founder receiving released tokens. Must be non-zero.
    /// @param totalA_ Tranche A total (wei). Must be > 0.
    /// @param cliffA_ Tranche A cliff (seconds). Must satisfy cliffA_ <= durationA_.
    /// @param durationA_ Tranche A total duration (seconds). Must be > 0.
    /// @param totalB_ Tranche B total (wei). Must be > 0.
    /// @param durationB_ Tranche B duration (seconds). Must be > 0.
    constructor(
        address eva_,
        address beneficiary_,
        uint256 totalA_,
        uint64 cliffA_,
        uint64 durationA_,
        uint256 totalB_,
        uint64 durationB_
    ) {
        require(eva_ != address(0) && beneficiary_ != address(0), "zero address");
        require(totalA_ > 0 && totalB_ > 0, "zero tranche amount");
        require(durationA_ > 0 && durationB_ > 0, "zero tranche duration");
        require(cliffA_ <= durationA_, "cliff exceeds duration");
        EVA = IEVA(eva_);
        BENEFICIARY = beneficiary_;
        TOTAL_A = totalA_;
        CLIFF_A = cliffA_;
        DURATION_A = durationA_;
        TOTAL_B = totalB_;
        DURATION_B = durationB_;
        TOTAL = totalA_ + totalB_;
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
