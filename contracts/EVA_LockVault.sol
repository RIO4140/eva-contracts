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

// src/EVA_LockVault.sol

 // ^0.8.24: verified with 0.8.24 locally; Remix deploys with 0.8.34

/*
 *  EVA Lock Vault — LockIncentiveEngine (engine #20)
 *  ============================================================
 *  Opt-in time-locked staking with a LINEAR lock multiplier, per the
 *  completed math research (~/workspace/research_notes/
 *  lock-incentive-engine-math-20261001-0029/report.md):
 *
 *  WHY LINEAR (production consensus — Curve/Balancer/Frax):
 *  - Linear weighting is EXACTLY split-neutral: splitting one lock
 *    into N locks yields identical total weight. Concave (sqrt)
 *    weighting is split-profitable (measured 1,472x-4,039x Sybil
 *    amplification) and must never be used without identity.
 *  - No major protocol uses sqrt/exponential lock curves.
 *
 *  RULES (immutable, no admin, no owner):
 *  1. Lock duration D in [90 days, 4 years]. NO early exit, ever.
 *  2. Multiplier fixed AT LOCK: m(D) = 1 + 3*D/4y  ->  1x .. 4x.
 *     Weight is STATIC during the lock: w = amount * m(D).
 *  3. Dual-stream rewards (EVA bonus pool + ETH pool), Synthetix-style
 *     rewardPerWeightedToken accumulator, O(1) reads. Pools are funded
 *     by anyone (treasury via governance in practice); the vault never
 *     mints.
 *  4. At expiry, principal STREAMS linearly over 90 days — no dump
 *     cliff. One-click evergreen re-lock available anytime.
 *  5. Advisory engine face: implements IEVAEngine (LOCK_TVL_WAD,
 *     LOCK_MULT_BP) and pokeHub() publishes to any hub that registered
 *     this vault. Hub is passed per-call: no circular constructor
 *     dependency.
 */
contract EVA_LockVault {
    // ----------------------------------------------------------------
    // Constants (immutable policy)
    // ----------------------------------------------------------------
    uint64  public constant MIN_LOCK = 90 days;
    uint64  public constant MAX_LOCK = 4 * 365 days;
    uint64  public constant STREAM_PERIOD = 90 days;
    uint256 public constant MULT_BASE_WAD = 1e18;          // 1x
    uint256 public constant MULT_MAX_WAD  = 4e18;          // 4x
    uint256 public constant MAX_MULT_BP   = 40000;         // 4x in basis points

    bytes32 public constant KEY_TVL  = keccak256("EVA.SIG.LOCK_TVL_WAD");
    bytes32 public constant KEY_MULT = keccak256("EVA.SIG.LOCK_MULT_BP");
    bytes32 public constant ENGINE_ID = keccak256("EVA.ENGINE.LOCK_INCENTIVE");

    // ----------------------------------------------------------------
    // Types
    // ----------------------------------------------------------------
    struct Position {
        uint128 amount;      // EVA locked (wei)
        uint128 weight;      // amount * m(D) / 1e18 (wad)
        uint64  unlockTime;
        bool    active;
    }
    struct Stream {
        uint128 total;       // principal streaming
        uint128 claimed;     // already released
        uint64  start;
        uint64  end;
    }
    struct RewardState {
        uint256 perWeight;   // accumulated reward per unit weight (1e18)
        uint256 carryover;   // funded while totalWeight == 0
    }

    // ----------------------------------------------------------------
    // Immutables & storage
    // ----------------------------------------------------------------
    IEVAToken public immutable EVA;

    uint256 public totalWeight;                 // sum of active weights
    uint256 public totalLocked;                 // sum of active principal
    uint256 public nextPositionId = 1;

    mapping(uint256 => Position) public positions;
    mapping(uint256 => address)  public positionOwner;
    mapping(address => Stream)   public streams;

    RewardState public evaRewards;              // EVA bonus pool state
    RewardState public ethRewards;              // ETH pool state
    mapping(address => uint256) public userEvaPerWeightPaid;
    mapping(address => uint256) public userEthPerWeightPaid;
    mapping(address => uint256) public userWeight;
    mapping(address => uint256) public accruedEVA;  // claimable EVA
    mapping(address => uint256) public accruedETH;  // claimable ETH
    mapping(address => uint256) public ethPull;     // ETH that could not be pushed (pull instead)

    bool private _locked;                       // reentrancy guard

    // ----------------------------------------------------------------
    // Events / errors
    // ----------------------------------------------------------------
    event Locked(address indexed user, uint256 indexed id, uint256 amount, uint256 weight, uint64 unlockTime);
    event Relocked(address indexed user, uint256 indexed oldId, uint256 indexed newId, uint256 weight);
    event Unlocked(address indexed user, uint256 indexed id, uint256 principal, uint64 streamEnd);
    event StreamClaimed(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 eva, uint256 eth);
    event RewardsFunded(address indexed from, uint256 eva, uint256 eth);
    event EthPullCredited(address indexed user, uint256 amount);
    event PulledETHWithdrawn(address indexed user, uint256 amount);

    error BadDuration();
    error ZeroAmount();
    error NotOwner();
    error NotActive();
    error StillLocked();
    error NothingVested();
    error NothingToClaim();
    error TransferFailed();
    error Reentrant();

    // ----------------------------------------------------------------
    // Constructor
    // ----------------------------------------------------------------
    constructor(address eva_) {
        require(eva_ != address(0), "zero EVA");
        EVA = IEVAToken(eva_);
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    // ----------------------------------------------------------------
    // Math
    // ----------------------------------------------------------------
    /// @notice Lock multiplier in wad: m(D) = 1 + 3*D/MAX_LOCK.
    function multiplierWad(uint64 duration) public pure returns (uint256) {
        if (duration < MIN_LOCK || duration > MAX_LOCK) revert BadDuration();
        // NOTE: cast to uint256 first — 3e18 fits in uint64, so without the
        // cast the multiplication would be done in 64-bit and overflow.
        return MULT_BASE_WAD + (3e18 * uint256(duration)) / uint256(MAX_LOCK);
    }

    // ----------------------------------------------------------------
    // Locking
    // ----------------------------------------------------------------
    /// @notice Lock EVA for `duration`. No early exit. Weight fixed now.
    function lock(uint256 amount, uint64 duration) external nonReentrant returns (uint256 id) {
        if (amount == 0) revert ZeroAmount();
        uint256 m = multiplierWad(duration); // reverts on bad duration
        _settle(msg.sender);

        id = nextPositionId++;
        uint128 w = uint128((amount * m) / 1e18);
        positions[id] = Position({
            amount: uint128(amount),
            weight: w,
            unlockTime: uint64(block.timestamp) + duration,
            active: true
        });
        positionOwner[id] = msg.sender;
        userWeight[msg.sender] += w;
        totalWeight += w;
        totalLocked += amount;

        _safeTransferFrom(msg.sender, address(this), amount);
        emit Locked(msg.sender, id, amount, w, uint64(block.timestamp) + duration);
    }

    /// @notice Evergreen re-lock: close position `id`, open a new lock on
    ///         the same principal. Allowed anytime; principal never leaves.
    function relock(uint256 id, uint64 newDuration) external nonReentrant returns (uint256 newId) {
        if (positionOwner[id] != msg.sender) revert NotOwner();
        Position storage p = positions[id];
        if (!p.active) revert NotActive();
        uint256 m = multiplierWad(newDuration);
        _settle(msg.sender);

        uint256 amt = p.amount;
        _removeWeight(msg.sender, p.weight);
        totalLocked -= amt;
        p.active = false;

        newId = nextPositionId++;
        uint128 w = uint128((amt * m) / 1e18);
        positions[newId] = Position({
            amount: uint128(amt),
            weight: w,
            unlockTime: uint64(block.timestamp) + newDuration,
            active: true
        });
        positionOwner[newId] = msg.sender;
        userWeight[msg.sender] += w;
        totalWeight += w;
        totalLocked += amt;

        emit Relocked(msg.sender, id, newId, w);
    }

    // ----------------------------------------------------------------
    // Unlock -> 90-day linear stream (no dump cliff)
    // ----------------------------------------------------------------
    /// @notice After expiry: principal streams over 90 days. Vested part
    ///         of any previous stream is paid out immediately.
    function unlock(uint256 id) external nonReentrant {
        if (positionOwner[id] != msg.sender) revert NotOwner();
        Position storage p = positions[id];
        if (!p.active) revert NotActive();
        if (block.timestamp < p.unlockTime) revert StillLocked();
        _settle(msg.sender);

        uint256 amt = p.amount;
        _removeWeight(msg.sender, p.weight);
        totalLocked -= amt;
        p.active = false;

        // Effects first: fold any unclaimed remainder of the old stream plus
        // the newly unlocked principal into ONE fresh 90-day stream.
        // (Claim your stream before unlocking if you want the old remainder
        // paid out immediately instead of re-streamed.)
        Stream storage s = streams[msg.sender];
        uint64 now_ = uint64(block.timestamp);
        s.total = uint128(uint256(s.total) - uint256(s.claimed) + amt);
        s.claimed = 0;
        s.start = now_;
        s.end = now_ + STREAM_PERIOD;

        // Interactions last. Soft payout: a fresh stream has 0 vested, so
        // this can never revert — unlock() cannot be bricked by an empty
        // or fully-claimed stream.
        _payoutStream(msg.sender);

        emit Unlocked(msg.sender, id, amt, s.end);
    }

    /// @notice Claim vested principal from the stream.
    function claimStream() external nonReentrant {
        _settle(msg.sender);
        if (_payoutStream(msg.sender) == 0) revert NothingVested();
    }

    /// @notice Pays out vested stream principal. Soft: returns the amount
    ///         paid (0 if nothing vested) and NEVER reverts on zero, so
    ///         unlock() can never be bricked by an empty stream.
    /// @dev    Effects (s.claimed) are updated BEFORE the external transfer.
    function _payoutStream(address user) internal returns (uint256 pay) {
        Stream storage s = streams[user];
        if (s.total == 0) return 0;
        uint256 vested = _vestedOf(s);
        pay = vested - s.claimed;
        if (pay == 0) return 0;
        s.claimed = uint128(vested);
        _safeTransfer(user, pay);
        emit StreamClaimed(user, pay);
    }

    function _vestedOf(Stream storage s) internal view returns (uint256) {
        if (block.timestamp >= s.end) return s.total;
        if (block.timestamp <= s.start) return 0;
        return (uint256(s.total) * (block.timestamp - s.start)) / (s.end - s.start);
    }

    /// @notice View: vested-but-unclaimed principal for `user`.
    function streamClaimable(address user) external view returns (uint256) {
        Stream storage s = streams[user];
        if (s.total == 0) return 0;
        uint256 vested;
        if (block.timestamp >= s.end) vested = s.total;
        else if (block.timestamp <= s.start) vested = 0;
        else vested = (uint256(s.total) * (block.timestamp - s.start)) / (s.end - s.start);
        return vested - s.claimed;
    }

    // ----------------------------------------------------------------
    // Rewards (dual stream: EVA bonus pool + ETH pool)
    // ----------------------------------------------------------------
    /// @notice Fund the EVA bonus pool. Callable by anyone (treasury via
    ///         governance in practice).
    function notifyRewardEVA(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _safeTransferFrom(msg.sender, address(this), amount);
        if (totalWeight == 0) {
            evaRewards.carryover += amount;
        } else {
            uint256 total = amount + evaRewards.carryover;
            evaRewards.carryover = 0;
            evaRewards.perWeight += (total * 1e18) / totalWeight;
        }
        emit RewardsFunded(msg.sender, amount, 0);
    }

    /// @notice Fund the ETH pool.
    function notifyRewardETH() external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        if (totalWeight == 0) {
            ethRewards.carryover += msg.value;
        } else {
            uint256 total = msg.value + ethRewards.carryover;
            ethRewards.carryover = 0;
            ethRewards.perWeight += (total * 1e18) / totalWeight;
        }
        emit RewardsFunded(msg.sender, 0, msg.value);
    }

    /// @notice Claim accrued EVA + ETH rewards.
    function claimRewards() external nonReentrant {
        _settle(msg.sender);
        uint256 e = accruedEVA[msg.sender];
        uint256 t = accruedETH[msg.sender];
        if (e == 0 && t == 0) revert NothingToClaim();
        accruedEVA[msg.sender] = 0;
        accruedETH[msg.sender] = 0;
        if (e > 0) _safeTransfer(msg.sender, e);
        if (t > 0) {
            // Push, but never brick the claimer: recipients that cannot
            // receive ETH get a pullable credit instead (mirrors EVA Core).
            // Audit note 2026-10-01: the old _safeTransferETH reverted the
            // whole claim for such recipients.
            (bool ok, ) = payable(msg.sender).call{value: t}("");
            if (!ok) {
                ethPull[msg.sender] += t;
                emit EthPullCredited(msg.sender, t);
            }
        }
        emit RewardsClaimed(msg.sender, e, t);
    }

    /// @notice Withdraw ETH rewards that could not be pushed. Pull-based, always available.
    function withdrawPulledETH() external nonReentrant {
        uint256 amt = ethPull[msg.sender];
        if (amt == 0) revert NothingToClaim();
        ethPull[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{value: amt}("");
        if (!ok) revert TransferFailed();
        emit PulledETHWithdrawn(msg.sender, amt);
    }

    /// @notice View: pending rewards for `user`.
    function earned(address user) external view returns (uint256 eva, uint256 eth) {
        uint256 w = userWeight[user];
        eva = accruedEVA[user] + (w * (evaRewards.perWeight - userEvaPerWeightPaid[user])) / 1e18;
        eth = accruedETH[user] + (w * (ethRewards.perWeight - userEthPerWeightPaid[user])) / 1e18;
    }

    function _settle(address user) internal {
        uint256 w = userWeight[user];
        if (w > 0) {
            accruedEVA[user] += (w * (evaRewards.perWeight - userEvaPerWeightPaid[user])) / 1e18;
            accruedETH[user] += (w * (ethRewards.perWeight - userEthPerWeightPaid[user])) / 1e18;
        }
        userEvaPerWeightPaid[user] = evaRewards.perWeight;
        userEthPerWeightPaid[user] = ethRewards.perWeight;
    }

    function _removeWeight(address user, uint256 w) internal {
        userWeight[user] -= w;
        totalWeight -= w;
    }

    // ----------------------------------------------------------------
    // Advisory engine face (IEVAEngine)
    // ----------------------------------------------------------------
    function engineId() external pure returns (bytes32) { return ENGINE_ID; }

    /// @notice IEVAEngine.signal: LOCK_TVL_WAD / LOCK_MULT_BP.
    function signal(bytes32 key) external view returns (uint256 value, uint256 updatedAt) {
        if (key == KEY_TVL)  return (totalLocked, block.timestamp);
        if (key == KEY_MULT) return (MAX_MULT_BP, block.timestamp);
        return (0, 0);
    }

    /// @notice Permissionless poke: publish to any hub that registered
    ///         this vault. Hub passed per-call (no circular dependency).
    function pokeHub(address hub) external {
        IEVAHub(hub).publish(KEY_TVL, totalLocked);
        IEVAHub(hub).publish(KEY_MULT, MAX_MULT_BP);
    }

    // ----------------------------------------------------------------
    // Safe transfers
    // ----------------------------------------------------------------
    function _safeTransfer(address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = address(EVA).call(
            abi.encodeWithSelector(IEVAToken.transfer.selector, to, amount)
        );
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "EVA transfer failed");
    }

    function _safeTransferFrom(address from, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = address(EVA).call(
            abi.encodeWithSelector(IEVAToken.transferFrom.selector, from, to, amount)
        );
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "EVA transferFrom failed");
    }

    receive() external payable {} // accept plain ETH funding
}

