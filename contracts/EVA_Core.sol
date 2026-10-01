// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// src/EVA_Core.sol

 // ^0.8.24: verified with 0.8.24 locally; Remix deploys with 0.8.34

/*
 *  EVA Core — "EVACore"
 *  ============================================================
 *  The sovereign heart of the EVA economy. Single file, no imports,
 *  no owner, no operator, no privileged roles — after deployment, no
 *  human (including the deployer) can change, pause, upgrade, rescue,
 *  or redirect anything outside the bounded on-chain governance below.
 *
 *  FORMULA: EVA = (AVA's beautiful unique features) + (all EVO v3 features)
 *           + (v4's new features) - (every known bug & inaccurate math).
 *
 *  DESIGN GOALS
 *  1) NO OWNER / NO OPERATOR — the deployer is recorded only as a
 *     *beneficiary* (founder allocation), never as a power.
 *  2) INTEGRAL-PRICED MARKET — sells execute at the true average price
 *     of the curve segment sold: payout = B(S) - B(S-T). A pump-and-dump
 *     can NEVER extract more ETH than purchases funded (no-drain invariant).
 *  3) REAL YIELD — stakers earn ETH from real trade taxes + EVA from a
 *     fixed emission pool. Lazy accounting: no keepers, no epochs.
 *  4) REAL ORACLE — Chainlink ETH/USD (Base) with staleness/validity checks
 *     and a last-good fallback. No human sets prices. Ever.
 *  5) ENGINE-READY — 25 advisory math engines plug in through ONE frozen
 *     interface (IEVAEngineHub). Engines SUGGEST within immutable bounds;
 *     the core DECIDES. No engine can mint, drain, pause, or redirect.
 *  6) BOUNDED SELF-GOVERNANCE — holders tune a small parameter set inside
 *     immutable [min,max], behind vote + timelock. The bounds ARE the law.
 *  7) ZERO-REGRET — every line written for formal verification: exact
 *     integer math, no floats, CEI everywhere, custom errors, NatSpec.
 *
 *  DISTRIBUTION (21,000,000 EVA, fixed forever):
 *    10,500,000  (50.00%)  curve reserve (in-contract market making)
 *     2,100,000  (10.00%)  AVA v1 -> EVA 1:1 migration pool
 *     2,100,000  (10.00%)  staking EVA emission pool (fixed schedule)
 *     1,050,000  ( 5.00%)  airdrop reserve (governance-distributed)
 *     2,250,000  (10.71%)  treasury EVA reserve (governance-spent)
 *     1,000,000  ( 4.76%)  founder liquid at deploy (payment, not power)
 *     2,000,000  ( 9.52%)  founder vesting: 1yr cliff, 3yr linear (satellite)
 *
 *  HONEST LIMITS: not independently audited yet. Immutability cuts both
 *  ways — a bug can never be fixed after deploy. Deploy only after the
 *  full 5-degree verification ladder (formal proof, fuzzing, symbolic
 *  execution, independent audits, bug bounty).
 */

// ---------------------------------------------------------------------------
// Interfaces (minimal, local — no imports, single file)
// ---------------------------------------------------------------------------
interface IERC20Burnable {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IChainlinkFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface ISecurityShield {
    function isFlagged(address user) external view returns (bool);
}

interface IIdentityNFT {
    function getTier(address user) external view returns (uint256);
}

/// @notice FROZEN engine-hub interface. This never changes: engines evolve
/// behind it, the core never does. Hub returns advisory signals; the core
/// clamps every signal to immutable bounds before use.
interface IEVAEngineHub {
    function signal(bytes32 key) external view returns (uint256 value, uint256 updatedAt);
}

// ---------------------------------------------------------------------------
// Custom errors (cheaper than strings, precise)
// ---------------------------------------------------------------------------
error ZeroAmount();
error ZeroAddress();
error TradingHalted();
error FlaggedByShield();
error Slippage();
error PastDeadline();
error InsufficientReserve();
error CapExceeded();
error LimitExceeded();
error PoolExhausted();
error NoPower();
error BadProposal();
error VotingClosed();
error AlreadyVoted();
error QuorumNotReached();
error TimelockPending();
error AlreadyExecuted();
error ParamOutOfBounds();
error NothingToClaim();
error NothingToRelease();
error VestingLocked();
error TransferFailed();
error Reentrant();
error BadHub();

contract EVACore {
    // -----------------------------------------------------------------------
    // ERC-20 core (self-contained)
    // -----------------------------------------------------------------------
    string public constant name = "EVA";
    string public constant symbol = "EVA";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // -----------------------------------------------------------------------
    // Immutable deployment facts — set once, never changeable by anyone
    // -----------------------------------------------------------------------
    uint256 public constant MAX_SUPPLY       = 21_000_000 * 1e18;
    uint256 public constant CURVE_POOL       = 9_870_000 * 1e18;  // 47% bonding-curve reserve
    uint256 public constant AVA_MIG_POOL     = 2_100_000 * 1e18;  // 10% AVA v1 -> EVA migration
    uint256 public constant EMISSION_POOL    = 2_100_000 * 1e18;  // 10% staking EVA emissions
    uint256 public constant AIRDROP_POOL     = 1_680_000 * 1e18;  // 8% airdrop reserve
    uint256 public constant TREASURY_POOL    = 1_250_000 * 1e18;  // ~5.95% ops treasury EVA reserve
    uint256 public constant ECOSYSTEM_POOL   = 1_000_000 * 1e18;  // ~4.76% ecosystem grants/listings
    uint256 public constant FOUNDER_LIQUID   = 500_000 * 1e18;    // founder liquid at deploy
    uint256 public constant FOUNDER_VESTING  = 2_500_000 * 1e18;  // founder vesting (satellite: 2M 3y/1y-cliff + 500k 1y linear)

    // Linked ecosystem (immutable)
    address public constant AVA_V1       = 0x77466B24EB2503ab06A2d664093A6CbA7bef7698;
    address public constant SHIELD       = 0xE56Fbad1E4705C00527f52e3850FdF70114aEBF0;
    address public constant IDENTITY_NFT = 0x49D6A3D22cC2a41613b66d37599064B81cB6d726;
    address public constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address public constant DEAD         = 0x000000000000000000000000000000000000dEaD;

    // Beneficiaries (payment addresses only — NOT roles, NOT powers)
    address public immutable FOUNDER;   // 500k liquid EVA + tax-ETH stream recipient
    address public immutable VESTING;   // founder vesting satellite (2.5M EVA: 2M 3y/1y-cliff + 500k 1y linear)

    // Engine signal keys (frozen — part of the interface forever)
    bytes32 public constant SIG_BUY_TAX_BP  = keccak256("EVA.SIG.BUY_TAX_BP");
    bytes32 public constant SIG_SELL_TAX_BP = keccak256("EVA.SIG.SELL_TAX_BP");

    // Curve math constants (phi-based exponential — the EVO lineage)
    uint256 public constant BASE_PRICE_USD8 = 100;            // $0.000001, 8 decimals
    uint256 public constant K_WAD = 962423650119;              // ln(1.6180339887)/500000, 1e18
    int256  private constant LN2_WAD = 693147180559945309;    // ln(2), 1e18

    // Staking emission (immutable)
    uint256 public immutable EMISSION_RATE_WPS;  // EVA-wei per second
    uint64  public immutable EMISSION_END;
    uint64  public immutable DEPLOYED_AT;

    // -----------------------------------------------------------------------
    // Mutable state (only changeable through trades, stakes, votes)
    // -----------------------------------------------------------------------
    uint256 public sold;                    // EVA-wei sold through the curve (price driver)
    uint256 public curveReserveETH;         // ETH backing sells (accounting)
    uint256 public unallocatedEthRewards;   // staking-share ETH waiting for first staker
    uint256 public treasuryAccrued;         // treasury share of tax ETH, pullable -> FOUNDER

    // Community EVA reserves (governance-spendable only)
    uint256 public airdropSpent;
    uint256 public treasuryEVASpent;
    uint256 public ecosystemEVASpent;

    // Engine hub (governance-settable; signals are advisory and clamped)
    address public engineHub;

    // Oracle
    uint256 public lastGoodEthUSD8;

    // TWAP ring (16 slots) + circuit breaker
    struct Obs { uint64 ts; uint256 cum; }
    Obs[16] public twapObs;
    uint8 public twapIdx;
    uint64 public lastObsTs;
    uint256 public cumPrice;
    uint64 public breakerRefTs;
    uint256 public breakerRefTwap;
    bool public breakerOn;
    uint64 public breakerUntil;

    // Staking
    uint256 public totalStaked;
    uint256 public accEthPerShare;
    uint256 public accEvoPerShare;
    uint64 public lastEmissionTs;
    mapping(address => uint256) public stakedOf;
    mapping(address => uint256) public ethDebt;
    mapping(address => uint256) public evoDebt;
    mapping(address => uint256) public ethPull;
    // EVA emission rewards actually paid out (capped at EMISSION_POOL).
    uint256 public evoEmitted;

    // Migration accounting
    uint256 public avaMigrated;

    // Anti-whale / anti-MEV
    mapping(address => uint64) public lastTradeBlock;
    mapping(address => uint64) public lastBuyDay;
    mapping(address => uint256) public dailyBuyUSD8;

    // Governable parameters (bounded; defaults at deploy)
    uint256 public buyTaxBP = 100;
    uint256 public sellTaxBP = 150;
    uint256 public maxBuyTxEVA = 100_000 * 1e18;
    uint256 public maxDailyBuyUSD8 = 500_000 * 1e8;
    uint256 public breakerBP = 4000;

    // Governance bounds (immutable — the constitution)
    uint256 private constant BUY_TAX_MIN = 50;
    uint256 private constant BUY_TAX_MAX = 500;
    uint256 private constant SELL_TAX_MIN = 100;
    uint256 private constant SELL_TAX_MAX = 800;
    uint256 private constant MAXBUY_MIN = 10_000 * 1e18;
    uint256 private constant MAXBUY_MAX = 1_000_000 * 1e18;
    uint256 private constant DAILY_MIN = 1_000 * 1e8;
    uint256 private constant DAILY_MAX = 5_000_000 * 1e8;
    uint256 private constant BREAKER_MIN = 2000;
    uint256 private constant BREAKER_MAX = 6000;

    // Governance state
    uint256 public proposalCount;
    struct Proposal {
        uint64 createdAt;
        uint64 voteEnd;
        uint64 eta;
        uint64 snapshotBlock;
        uint8 param;           // 0..4 = params, 5 = engineHub, 6 = community spend
        uint8 spendPool;       // param 6 only: 1 = airdrop, 2 = treasury, 3 = ecosystem
        address spendTo;       // param 6 only
        uint256 newValue;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        // Votable supply frozen at creation: quorum is judged against the
        // tokens that could actually vote (totalSupply minus the core's own
        // pools and the locked vesting balance), not against later burns.
        // This keeps governance live at launch (founder can run the deploy
        // ceremony) while his unilateral control decays as supply circulates.
        uint256 votableAt;
    }
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    uint256 public constant VOTING_PERIOD = 3 days;
    uint256 public constant TIMELOCK_DELAY = 2 days;
    uint256 public constant PROPOSE_THRESHOLD = 100_000 * 1e18;
    uint256 public constant QUORUM_BP = 400;

    // Voting-power checkpoints (balance + staked, counted ONCE)
    struct CP { uint64 blk; uint256 power; }
    mapping(address => CP[]) public checkpoints;

    // Engine signals older than this are treated as absent — the core keeps
    // its own values rather than acting on stale advice.
    uint256 private constant ENGINE_SIGNAL_MAX_AGE = 1 days;

    // Reentrancy guard (no imports)
    uint256 private _locked = 1;
    modifier nonReentrant() {
        if (_locked != 1) revert Reentrant();
        _locked = 2;
        _;
        _locked = 1;
    }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------
    event Buy(address indexed buyer, uint256 ethIn, uint256 evaOut, uint256 priceUSD8);
    event Sell(address indexed seller, uint256 evaIn, uint256 ethOut, uint256 priceUSD8);
    event FundReserve(address indexed from, uint256 ethIn);
    event TaxRouted(uint256 toStakers, uint256 toTreasury, uint256 burnedEVA);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 ethAmt, uint256 evaAmt);
    event EthPullCredited(address indexed user, uint256 amount);
    event PulledETHWithdrawn(address indexed user, uint256 amount);
    event TreasuryPaidOut(address indexed to, uint256 amount);
    event MigratedAVA(address indexed user, uint256 amount);
    event ShieldUnreachable(address indexed user);
    event BreakerTripped(uint256 refTwap, uint256 curTwap);
    event BreakerCleared(uint256 curTwap);
    event OracleFallback(uint256 lastGoodPrice);
    event ProposalCreated(uint256 indexed id, address indexed proposer, uint8 param, uint256 newValue);
    event Voted(uint256 indexed id, address indexed voter, bool support, uint256 power);
    event ProposalExecuted(uint256 indexed id, uint8 param, uint256 newValue);
    event BurnedForDeflation(uint256 evaAmount, uint256 ethSpent);
    event EngineHubSet(address indexed hub);
    event CommunitySpent(uint8 indexed pool, address indexed to, uint256 amount);
    event EngineSignalUsed(bytes32 indexed key, uint256 value);

    // -----------------------------------------------------------------------
    // Constructor — the ONLY privileged moment. After this, no roles exist.
    // -----------------------------------------------------------------------
    constructor(address founder_, address vesting_) {
        if (founder_ == address(0) || vesting_ == address(0)) revert ZeroAddress();
        FOUNDER = founder_;
        VESTING = vesting_;
        DEPLOYED_AT = uint64(block.timestamp);
        EMISSION_END = uint64(block.timestamp + 4 * 365 days);
        lastEmissionTs = uint64(block.timestamp);

        // Fresh curve: EVA is a new economy, price starts at BASE.
        sold = 0;

        // Fixed distribution — every wei accounted for, sums to MAX_SUPPLY.
        _mint(address(this), CURVE_POOL + AVA_MIG_POOL + EMISSION_POOL + AIRDROP_POOL + TREASURY_POOL + ECOSYSTEM_POOL);
        _mint(founder_, FOUNDER_LIQUID);
        _mint(vesting_, FOUNDER_VESTING);

        EMISSION_RATE_WPS = EMISSION_POOL / (4 * 365 days);

        // Seed oracle + TWAP. Fail fast if the oracle is unreachable at deploy.
        uint256 p0 = _readEthPrice();
        require(p0 > 0, "oracle unreachable at deploy");
        lastGoodEthUSD8 = p0;
        uint256 spot = _priceWad(sold);
        lastObsTs = uint64(block.timestamp);
        twapObs[0] = Obs({ts: uint64(block.timestamp), cum: 0});
        breakerRefTs = uint64(block.timestamp);
        breakerRefTwap = spot;

        _checkpoint(founder_);
    }

    // -----------------------------------------------------------------------
    // ERC-20 internals
    // -----------------------------------------------------------------------
    function _mint(address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += amount;
        balanceOf[to] += amount;
        _checkpoint(to);
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        if (balanceOf[from] < amount) revert CapExceeded();
        unchecked {
            balanceOf[from] -= amount;
            totalSupply -= amount;
        }
        _checkpoint(from);
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf[from] < amount) revert CapExceeded();
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        _checkpoint(from);
        _checkpoint(to);
        emit Transfer(from, to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            if (a < amount) revert CapExceeded();
            unchecked { allowance[from][msg.sender] = a - amount; }
        }
        _transfer(from, to, amount);
        return true;
    }

    // -----------------------------------------------------------------------
    // Fixed-point math: e^x and ln(x) in 1e18 WAD. Pure, no dependencies.
    // The no-drain invariant lives here: sells are priced by the exact
    // integral of the curve segment sold — never the spot price.
    // -----------------------------------------------------------------------

    /// @notice e^x, x signed WAD. Supports |x| <= ~64 (economically unreachable beyond).
    function _expWad(int256 x) internal pure returns (uint256) {
        bool neg = x < 0;
        uint256 ax = neg ? uint256(-x) : uint256(x);
        uint256 k = ax / uint256(LN2_WAD);
        require(k <= 64, "exp overflow");
        uint256 r = ax - k * uint256(LN2_WAD);
        uint256 term = 1e18;
        uint256 sum = 1e18;
        for (uint256 n = 1; n <= 13; n++) {
            term = (term * r) / 1e18 / n;
            sum += term;
        }
        uint256 res = sum * (1 << k);
        if (neg) {
            res = (1e36) / res;
        }
        return res;
    }

    /// @notice ln(x), x unsigned WAD, x > 0. Returns signed WAD.
    function _lnWad(uint256 x) internal pure returns (int256) {
        require(x > 0, "ln(0)");
        int256 k2 = 0;
        while (x >= 2e18) { x >>= 1; k2 += 1; }
        while (x < 1e18) { x <<= 1; k2 -= 1; }
        uint256 m = x;
        uint256 y = ((m - 1e18) * 1e18) / (m + 1e18);
        uint256 y2 = (y * y) / 1e18;
        uint256 term = y;
        uint256 sum = y;
        for (uint256 i = 1; i <= 8; i++) {
            term = (term * y2) / 1e18;
            sum += term / (2 * i + 1);
        }
        int256 lnM = int256(2 * sum);
        return k2 * LN2_WAD + lnM;
    }

    /// @notice Spot price in usd8 (1e8 = $1) at a given sold (EVA-wei).
    /// price(s) = BASE * e^(k*s).
    function _priceWad(uint256 soldW) internal pure returns (uint256) {
        uint256 xWad = (K_WAD * soldW) / 1e18;
        uint256 e = _expWad(int256(xWad));
        return (BASE_PRICE_USD8 * e) / 1e18;
    }

    /// @notice Exact USD8 proceeds of selling `deltaW` EVA starting at `soldW`:
    /// integral = (P(s) - P(s-d)) / k. Rounds down (favors the protocol).
    /// THE NO-DRAIN INVARIANT: payout = B(S) - B(S-T). Extraction can never
    /// exceed what purchases funded — pump-and-dump is mathematically unprofitable.
    function _sellProceedsUSD8(uint256 soldW, uint256 deltaW) internal pure returns (uint256) {
        uint256 p0 = _priceWad(soldW);
        uint256 p1 = _priceWad(soldW - deltaW);
        if (p0 <= p1) return 0;
        return ((p0 - p1) * 1e18) / K_WAD;
    }

    /// @notice EVA-wei out for a buy of `netUSD8` net of tax, starting at `soldW`.
    function _evoOutForUSD(uint256 soldW, uint256 netUSD8) internal pure returns (uint256) {
        uint256 p0 = _priceWad(soldW);
        uint256 p1 = p0 + (netUSD8 * K_WAD) / 1e18;
        if (p1 <= p0) return 0;
        int256 ln1 = _lnWad((p1 * 1e18) / BASE_PRICE_USD8);
        int256 ln0 = _lnWad((p0 * 1e18) / BASE_PRICE_USD8);
        if (ln1 <= ln0) return 0;
        uint256 dWad = uint256(ln1 - ln0);
        return (dWad * 1e18) / K_WAD;
    }

    // -----------------------------------------------------------------------
    // Oracle: Chainlink ETH/USD with validity checks + last-good fallback.
    // -----------------------------------------------------------------------
    function _readEthPrice() internal returns (uint256) {
        // Full graceful degradation: no code at the feed, a reverting feed,
        // or insane data all fall through to the last-good price.
        // (Solidity try/catch does NOT catch returndata-decoding failures,
        // so the code-length check comes first — verified by test.)
        if (CHAINLINK_ETH_USD.code.length > 0) {
            try IChainlinkFeed(CHAINLINK_ETH_USD).latestRoundData() returns (
                uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
            ) {
                bool sane = answer > 0
                    && answeredInRound >= roundId
                    && block.timestamp >= updatedAt
                    && block.timestamp - updatedAt <= 1 days
                    && uint256(answer) >= 1e10
                    && uint256(answer) <= 1e14;
                if (sane) {
                    lastGoodEthUSD8 = uint256(answer);
                    return uint256(answer);
                }
            } catch {}
        }
        emit OracleFallback(lastGoodEthUSD8);
        return lastGoodEthUSD8;
    }

    function ethPriceUSD8() external returns (uint256) {
        return _readEthPrice();
    }

    // -----------------------------------------------------------------------
    // TWAP (true time-weighted, 1h window) + circuit breaker — all lazy.
    // -----------------------------------------------------------------------
    function _pokeTwap(uint256 spotUSD8) internal {
        uint64 nowTs = uint64(block.timestamp);
        uint256 dt = nowTs - lastObsTs;
        if (dt > 0) {
            cumPrice += spotUSD8 * dt;
            lastObsTs = nowTs;
            twapIdx = (twapIdx + 1) % 16;
            twapObs[twapIdx] = Obs({ts: nowTs, cum: cumPrice});
        }
    }

    /// @notice 1-hour TWAP in usd8. Falls back to spot when history is thin.
    function getTwapUSD8() public view returns (uint256) {
        uint64 nowTs = uint64(block.timestamp);
        uint256 target = nowTs > 3600 ? nowTs - 3600 : 0;
        uint256 bestCum = 0;
        uint64 bestTs = 0;
        for (uint8 i = 0; i < 16; i++) {
            Obs memory o = twapObs[i];
            if (o.ts == 0 || o.ts > nowTs) continue;
            if (o.ts <= target && o.ts >= bestTs) { bestTs = o.ts; bestCum = o.cum; }
        }
        uint256 curCum = cumPrice + _priceWad(sold) * (nowTs - lastObsTs);
        if (bestTs == 0 || nowTs - bestTs < 300) {
            return _priceWad(sold);
        }
        return (curCum - bestCum) / (nowTs - bestTs);
    }

    /// @notice Circuit breaker: trips on steep TWAP drawdown, clears on
    /// recovery or after 24h — automatic, no human reset exists.
    function _checkBreaker() internal {
        uint64 nowTs = uint64(block.timestamp);
        uint256 twap = getTwapUSD8();
        if (breakerOn) {
            bool recovered = twap >= (breakerRefTwap * (10000 - breakerBP / 2)) / 10000;
            if (recovered || nowTs >= breakerUntil) {
                breakerOn = false;
                emit BreakerCleared(twap);
            }
            return;
        }
        if (nowTs - breakerRefTs >= 3600) {
            if (twap * 10000 < breakerRefTwap * (10000 - breakerBP)) {
                breakerOn = true;
                breakerUntil = nowTs + 24 hours;
                emit BreakerTripped(breakerRefTwap, twap);
                return;
            }
            breakerRefTs = nowTs;
            breakerRefTwap = twap;
        }
    }

    function _requireTradingLive() internal {
        _checkBreaker();
        if (breakerOn) revert TradingHalted();
    }

    // -----------------------------------------------------------------------
    // Security shield (graceful) + engine-advisory tax tiers.
    // THE ADVISORY PATTERN: engines SUGGEST, the core DECIDES. A hub signal
    // is accepted only inside the immutable [min,max] bounds; a dead hub
    // can never change fees or brick trading.
    // -----------------------------------------------------------------------
    function _shieldCheck(address user) internal {
        // Graceful in the full sense: a shield with no code, a shield that
        // reverts, or a shield that returns garbage can never brick trading.
        // (Solidity try/catch does NOT catch returndata-decoding failures,
        // so the code-length check comes first — verified by test.)
        if (SHIELD.code.length == 0) {
            emit ShieldUnreachable(user);
            return;
        }
        try ISecurityShield(SHIELD).isFlagged(user) returns (bool flagged) {
            if (flagged) revert FlaggedByShield();
        } catch {
            emit ShieldUnreachable(user);
        }
    }

    /// @notice Read one advisory signal from the engine hub (frozen interface).
    /// Returns (value, used): `used` is false when there is no hub, the call
    /// fails, or the value is stale — the core then keeps its own value.
    function engineSignal(bytes32 key) public view returns (uint256 value, bool used) {
        address hub = engineHub;
        if (hub == address(0) || hub.code.length == 0) return (0, false);
        try IEVAEngineHub(hub).signal(key) returns (uint256 v, uint256 updatedAt) {
            if (updatedAt == 0
                || updatedAt > block.timestamp
                || block.timestamp - updatedAt > ENGINE_SIGNAL_MAX_AGE) {
                return (0, false);
            }
            return (v, true);
        } catch {
            return (0, false);
        }
    }

    /// @notice Adaptive tax tiers: governance base, optionally refined by
    /// engine signals — ALWAYS clamped to immutable bounds.
    function _taxTiers() internal view returns (uint256 buyBP, uint256 sellBP) {
        buyBP = buyTaxBP;
        sellBP = sellTaxBP;
        (uint256 sigBuy, bool usedBuy) = engineSignal(SIG_BUY_TAX_BP);
        if (usedBuy && sigBuy >= BUY_TAX_MIN && sigBuy <= BUY_TAX_MAX) buyBP = sigBuy;
        (uint256 sigSell, bool usedSell) = engineSignal(SIG_SELL_TAX_BP);
        if (usedSell && sigSell >= SELL_TAX_MIN && sigSell <= SELL_TAX_MAX) sellBP = sigSell;
        uint256 twap = getTwapUSD8();
        if (twap >= 1e12) {
            buyBP += 50; sellBP += 100;
            // Re-clamp AFTER the TWAP bump: the immutable bounds hold always.
            if (buyBP > BUY_TAX_MAX) buyBP = BUY_TAX_MAX;
            if (sellBP > SELL_TAX_MAX) sellBP = SELL_TAX_MAX;
        }
    }

    // -----------------------------------------------------------------------
    // Staking pool accounting (lazy — no keepers, no epochs)
    // -----------------------------------------------------------------------
    function _updatePools() internal {
        uint64 nowTs = uint64(block.timestamp);
        if (totalStaked > 0 && unallocatedEthRewards > 0) {
            accEthPerShare += (unallocatedEthRewards * 1e18) / totalStaked;
            unallocatedEthRewards = 0;
        }
        if (nowTs > lastEmissionTs && nowTs <= EMISSION_END) {
            uint256 pending = EMISSION_RATE_WPS * (nowTs - lastEmissionTs);
            if (pending > 0 && totalStaked > 0) {
                accEvoPerShare += (pending * 1e18) / totalStaked;
            }
            lastEmissionTs = nowTs;
        } else if (nowTs > EMISSION_END && lastEmissionTs < EMISSION_END) {
            uint256 pending = EMISSION_RATE_WPS * (EMISSION_END - lastEmissionTs);
            if (pending > 0 && totalStaked > 0) {
                accEvoPerShare += (pending * 1e18) / totalStaked;
            }
            lastEmissionTs = EMISSION_END;
        }
    }

    function _pendingEth(address user) internal view returns (uint256) {
        uint256 acc = accEthPerShare;
        if (totalStaked > 0 && unallocatedEthRewards > 0) {
            acc += (unallocatedEthRewards * 1e18) / totalStaked;
        }
        uint256 gross = (stakedOf[user] * acc) / 1e18;
        return gross > ethDebt[user] ? gross - ethDebt[user] : 0;
    }

    function _pendingEvo(address user) internal view returns (uint256) {
        uint256 acc = accEvoPerShare;
        uint64 nowTs = uint64(block.timestamp);
        uint64 upTo = nowTs > EMISSION_END ? EMISSION_END : nowTs;
        if (upTo > lastEmissionTs && totalStaked > 0) {
            acc += (EMISSION_RATE_WPS * (upTo - lastEmissionTs) * 1e18) / totalStaked;
        }
        uint256 gross = (stakedOf[user] * acc) / 1e18;
        uint256 v = gross > evoDebt[user] ? gross - evoDebt[user] : 0;
        // Never promise more than the pool's remaining headroom.
        uint256 left = evoEmitted >= EMISSION_POOL ? 0 : EMISSION_POOL - evoEmitted;
        return v > left ? left : v;
    }

    // -----------------------------------------------------------------------
    // Voting-power checkpoints (balance + staked counted ONCE)
    // -----------------------------------------------------------------------
    /// @notice Tokens that can actually vote: everything not locked in the
    ///         core's own pools or the founder vesting contract.
    function _votableSupply() internal view returns (uint256) {
        return totalSupply - balanceOf[address(this)] - balanceOf[VESTING];
    }

    function _votingPowerOf(address a) internal view returns (uint256) {
        return balanceOf[a] + stakedOf[a];
    }

    function _checkpoint(address a) internal {
        uint256 p = _votingPowerOf(a);
        CP[] storage cps = checkpoints[a];
        if (cps.length > 0 && cps[cps.length - 1].blk == block.number) {
            cps[cps.length - 1].power = p;
        } else {
            cps.push(CP({blk: uint64(block.number), power: p}));
        }
    }

    function powerAt(address a, uint256 blockNumber) public view returns (uint256) {
        CP[] storage cps = checkpoints[a];
        uint256 n = cps.length;
        if (n == 0) return 0;
        if (blockNumber >= cps[n - 1].blk) return cps[n - 1].power;
        if (blockNumber < cps[0].blk) return 0;
        uint256 lo = 0;
        uint256 hi = n - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (cps[mid].blk <= blockNumber) lo = mid;
            else hi = mid - 1;
        }
        return cps[lo].power;
    }

    /// @notice AVA IdentityNFT boost: +25% voting power for tier holders (bounded, graceful).
    function _nftBoostBP(address a) internal view returns (uint256) {
        if (IDENTITY_NFT.code.length == 0) return 0;
        try IIdentityNFT(IDENTITY_NFT).getTier(a) returns (uint256 tier) {
            if (tier > 0) return 2500;
        } catch {}
        return 0;
    }

    // -----------------------------------------------------------------------
    // TRADING — the autonomous market. No owner, no operator, no activation.
    // -----------------------------------------------------------------------

    /// @notice Anyone may deepen the curve reserve at any time. Permissionless liquidity.
    function fundReserve() external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        curveReserveETH += msg.value;
        emit FundReserve(msg.sender, msg.value);
    }

    /// @notice Plain ETH sent to the contract deepens the curve reserve.
    receive() external payable {
        curveReserveETH += msg.value;
        emit FundReserve(msg.sender, msg.value);
    }

    /// @notice Buy EVA with ETH at the exact integral curve price.
    function buy(uint256 minEvaOut, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 evaOut)
    {
        if (msg.value == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert PastDeadline();
        _requireTradingLive();
        _shieldCheck(msg.sender);

        if (lastTradeBlock[msg.sender] == block.number) revert LimitExceeded();
        lastTradeBlock[msg.sender] = uint64(block.number);

        uint256 ethUSD8 = _readEthPrice();
        uint256 grossUSD8 = (msg.value * ethUSD8) / 1e18;

        uint64 day = uint64(block.timestamp / 1 days);
        if (lastBuyDay[msg.sender] != day) {
            lastBuyDay[msg.sender] = day;
            dailyBuyUSD8[msg.sender] = 0;
        }
        if (dailyBuyUSD8[msg.sender] + grossUSD8 > maxDailyBuyUSD8) revert LimitExceeded();
        dailyBuyUSD8[msg.sender] += grossUSD8;

        (uint256 buyBP,) = _taxTiers();
        uint256 taxETH = (msg.value * buyBP) / 10000;
        uint256 netETH = msg.value - taxETH;
        uint256 netUSD8 = (netETH * ethUSD8) / 1e18;

        evaOut = _evoOutForUSD(sold, netUSD8);
        if (evaOut == 0) revert ZeroAmount();
        if (evaOut < minEvaOut) revert Slippage();
        if (evaOut > maxBuyTxEVA) revert CapExceeded();
        uint256 freeBal = curveEvaFree();
        if (evaOut > freeBal) revert PoolExhausted();

        // Tax route: 50% stakers / 30% treasury / 20% protocol buy-and-burn.
        uint256 toStakers = (taxETH * 5000) / 10000;
        uint256 toTreasury = (taxETH * 3000) / 10000;
        uint256 toBurn = taxETH - toStakers - toTreasury;

        // The user's buy moves the curve first...
        sold += evaOut;

        // ...then the protocol's buy-and-burn executes at the POST-buy price,
        // like any real second buyer. Its ETH funds the reserve below — every
        // wei of msg.value is accounted; nothing strands in the raw balance.
        uint256 burnedEVA = 0;
        if (toBurn > 0) {
            burnedEVA = _evoOutForUSD(sold, (toBurn * ethUSD8) / 1e18);
            if (burnedEVA > 0 && burnedEVA <= freeBal - evaOut) {
                _burn(address(this), burnedEVA);
                sold += burnedEVA;
                emit BurnedForDeflation(burnedEVA, toBurn);
            } else {
                toStakers += toBurn;
                toBurn = 0;
            }
        }

        curveReserveETH += netETH + toBurn;
        if (toStakers > 0) {
            if (totalStaked > 0) accEthPerShare += (toStakers * 1e18) / totalStaked;
            else unallocatedEthRewards += toStakers;
        }
        if (toTreasury > 0) treasuryAccrued += toTreasury;

        _updatePools();
        _pokeTwap(_priceWad(sold));
        _transfer(address(this), msg.sender, evaOut);

        emit Buy(msg.sender, msg.value, evaOut, _priceWad(sold));
        emit TaxRouted(toStakers, toTreasury, burnedEVA);
    }

    /// @notice Sell EVA for ETH at the exact average (integral) execution price.
    /// Sellers can NEVER extract more than the curve mathematics funded.
    function sell(uint256 evaAmt, uint256 minEthOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        if (evaAmt == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert PastDeadline();
        _requireTradingLive();
        _shieldCheck(msg.sender);
        if (evaAmt > sold) revert CapExceeded();

        if (lastTradeBlock[msg.sender] == block.number) revert LimitExceeded();
        lastTradeBlock[msg.sender] = uint64(block.number);

        uint256 ethUSD8 = _readEthPrice();
        uint256 grossUSD8 = _sellProceedsUSD8(sold, evaAmt);
        if (grossUSD8 == 0) revert ZeroAmount();
        uint256 grossETH = (grossUSD8 * 1e18) / ethUSD8;

        (, uint256 sellBP) = _taxTiers();
        uint256 taxETH = (grossETH * sellBP) / 10000;
        ethOut = grossETH - taxETH;
        if (ethOut < minEthOut) revert Slippage();

        uint256 toStakers = taxETH / 2;
        uint256 toTreasury = taxETH - toStakers;

        if (curveReserveETH < grossETH) revert InsufficientReserve();
        unchecked { curveReserveETH -= grossETH; }
        sold -= evaAmt;

        if (toStakers > 0) {
            if (totalStaked > 0) accEthPerShare += (toStakers * 1e18) / totalStaked;
            else unallocatedEthRewards += toStakers;
        }
        if (toTreasury > 0) treasuryAccrued += toTreasury;

        _updatePools();
        _pokeTwap(_priceWad(sold));

        _transfer(msg.sender, address(this), evaAmt);
        _burn(address(this), evaAmt);

        (bool ok, ) = payable(msg.sender).call{value: ethOut}("");
        if (!ok) revert TransferFailed();

        emit Sell(msg.sender, evaAmt, ethOut, _priceWad(sold));
        emit TaxRouted(toStakers, toTreasury, 0);
    }

    /// @notice Permissionless treasury payout: anyone can trigger the push to FOUNDER.
    function payoutTreasury() external nonReentrant {
        uint256 amt = treasuryAccrued;
        if (amt == 0) revert NothingToClaim();
        treasuryAccrued = 0;
        (bool ok, ) = payable(FOUNDER).call{value: amt}("");
        if (!ok) revert TransferFailed();
        emit TreasuryPaidOut(FOUNDER, amt);
    }

    // -----------------------------------------------------------------------
    // Trading previews (views)
    // -----------------------------------------------------------------------
    function buyPreview(uint256 ethIn) external view returns (uint256 evaOut, uint256 priceUSD8) {
        if (ethIn == 0 || lastGoodEthUSD8 == 0) return (0, _priceWad(sold));
        (uint256 buyBP,) = _taxTiers();
        uint256 netETH = ethIn - (ethIn * buyBP) / 10000;
        uint256 netUSD8 = (netETH * lastGoodEthUSD8) / 1e18;
        evaOut = _evoOutForUSD(sold, netUSD8);
        priceUSD8 = _priceWad(sold);
    }

    function sellPreview(uint256 evaAmt) external view returns (uint256 ethOut, uint256 priceUSD8) {
        if (evaAmt == 0 || evaAmt > sold || lastGoodEthUSD8 == 0) return (0, _priceWad(sold));
        uint256 grossUSD8 = _sellProceedsUSD8(sold, evaAmt);
        uint256 grossETH = (grossUSD8 * 1e18) / lastGoodEthUSD8;
        (, uint256 sellBP) = _taxTiers();
        ethOut = grossETH - (grossETH * sellBP) / 10000;
        priceUSD8 = _priceWad(sold);
    }

    function spotPriceUSD8() external view returns (uint256) {
        return _priceWad(sold);
    }

    function marketState()
        external
        view
        returns (
            uint256 _sold,
            uint256 _spotUSD8,
            uint256 _twapUSD8,
            uint256 _reserveETH,
            uint256 _curveEVALeft,
            bool _breakerOn
        )
    {
        _sold = sold;
        _spotUSD8 = _priceWad(sold);
        _twapUSD8 = getTwapUSD8();
        _reserveETH = curveReserveETH;
        _curveEVALeft = balanceOf[address(this)];
        _breakerOn = breakerOn;
    }

    // -----------------------------------------------------------------------
    // STAKING — internal, dual rewards (ETH from real taxes + EVA emissions).
    // -----------------------------------------------------------------------
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _updatePools();
        _harvest(msg.sender);
        _transfer(msg.sender, address(this), amount);
        stakedOf[msg.sender] += amount;
        totalStaked += amount;
        ethDebt[msg.sender] = (stakedOf[msg.sender] * accEthPerShare) / 1e18;
        evoDebt[msg.sender] = (stakedOf[msg.sender] * accEvoPerShare) / 1e18;
        _checkpoint(msg.sender);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0 || amount > stakedOf[msg.sender]) revert ZeroAmount();
        _updatePools();
        _harvest(msg.sender);
        unchecked {
            stakedOf[msg.sender] -= amount;
            totalStaked -= amount;
        }
        ethDebt[msg.sender] = (stakedOf[msg.sender] * accEthPerShare) / 1e18;
        evoDebt[msg.sender] = (stakedOf[msg.sender] * accEvoPerShare) / 1e18;
        _checkpoint(msg.sender);
        _transfer(address(this), msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external nonReentrant {
        _updatePools();
        _harvest(msg.sender);
    }

    function _harvest(address user) internal {
        uint256 e = _pendingEth(user);
        uint256 v = _pendingEvo(user); // already capped at EMISSION_POOL headroom
        if (e == 0 && v == 0) return;
        ethDebt[user] = (stakedOf[user] * accEthPerShare) / 1e18;
        evoDebt[user] = (stakedOf[user] * accEvoPerShare) / 1e18;
        if (v > 0) {
            evoEmitted += v;
            _transfer(address(this), user, v);
        }
        if (e > 0) {
            // Push, but never brick the caller: recipients that cannot receive
            // ETH get a pullable credit instead — staking can never get stuck.
            (bool ok, ) = payable(user).call{value: e}("");
            if (!ok) {
                ethPull[user] += e;
                emit EthPullCredited(user, e);
            }
        }
        emit RewardsClaimed(user, e, v);
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

    function pendingRewards(address user)
        external
        view
        returns (uint256 ethAmt, uint256 evaAmt)
    {
        ethAmt = _pendingEth(user);
        evaAmt = _pendingEvo(user);
    }

    // -----------------------------------------------------------------------
    // Pool reservation: migration / emission / community pools are pre-funded
    // at deploy and SACRED — curve trading and burns can never consume them.
    // -----------------------------------------------------------------------
    function _emissionEmitted() internal view returns (uint256) {
        uint64 upTo = uint64(block.timestamp) > EMISSION_END ? EMISSION_END : uint64(block.timestamp);
        if (upTo <= DEPLOYED_AT) return 0;
        return EMISSION_RATE_WPS * (upTo - DEPLOYED_AT);
    }

    function _reservedPools() internal view returns (uint256) {
        uint256 emitted = _emissionEmitted();
        uint256 emissionLeft = emitted >= EMISSION_POOL ? 0 : EMISSION_POOL - emitted;
        return (AVA_MIG_POOL - avaMigrated)
             + (AIRDROP_POOL - airdropSpent)
             + (TREASURY_POOL - treasuryEVASpent)
             + (ECOSYSTEM_POOL - ecosystemEVASpent)
             + emissionLeft;
    }

    /// @notice EVA in the contract freely usable by the curve (buys + burns).
    function curveEvaFree() public view returns (uint256) {
        uint256 bal = balanceOf[address(this)];
        uint256 reserved = _reservedPools();
        return bal > reserved ? bal - reserved : 0;
    }

    // -----------------------------------------------------------------------
    // MIGRATION — AVA v1 -> EVA 1:1, permissionless, capped by its pool.
    // Burn-and-transfer: old AVA goes to DEAD, EVA comes from the pre-funded
    // pool (never minted) — MAX_SUPPLY stays a hard cap. Balance-delta
    // accounting: credit exactly what arrived at DEAD.
    // -----------------------------------------------------------------------
    function migrateFromAVA(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 deadBefore = IERC20Burnable(AVA_V1).balanceOf(DEAD);
        bool ok = IERC20Burnable(AVA_V1).transferFrom(msg.sender, DEAD, amount);
        if (!ok) revert TransferFailed();
        uint256 received = IERC20Burnable(AVA_V1).balanceOf(DEAD) - deadBefore;
        if (received == 0) revert ZeroAmount();
        if (avaMigrated + received > AVA_MIG_POOL) revert PoolExhausted();
        avaMigrated += received;
        _transfer(address(this), msg.sender, received);
        emit MigratedAVA(msg.sender, received);
    }

    // -----------------------------------------------------------------------
    // BOUNDED SELF-GOVERNANCE — the coin can adapt, but never escape its bounds.
    // Any holder with >= 100k voting power may propose; voting lasts 3 days;
    // execution waits 2 more days (timelock); ANYONE may execute.
    // Tunables (each strictly inside immutable [min,max]):
    //   0 = buyTaxBP        [50, 500]
    //   1 = sellTaxBP       [100, 800]
    //   2 = maxBuyTxEVA     [10_000e18, 1_000_000e18]
    //   3 = maxDailyBuyUSD8 [1_000e8, 5_000_000e8]
    //   4 = breakerBP       [2000, 6000]
    //   5 = engineHub       (any non-zero address; signals stay clamped)
    //   6 = community spend (pool 1 = airdrop, 2 = treasury, 3 = ecosystem; capped by pool)
    // There is no admin, no multisig, no backdoor — the bounds ARE the constitution.
    // -----------------------------------------------------------------------
    function propose(uint8 param, uint256 newValue, string calldata description)
        external
        returns (uint256 id)
    {
        if (param > 5) revert BadProposal();
        _validateParam(param, newValue);
        if (_votingPowerOf(msg.sender) < PROPOSE_THRESHOLD) revert NoPower();

        id = ++proposalCount;
        Proposal storage p = proposals[id];
        p.createdAt = uint64(block.timestamp);
        p.voteEnd = uint64(block.timestamp + VOTING_PERIOD);
        p.eta = uint64(block.timestamp + VOTING_PERIOD + TIMELOCK_DELAY);
        p.snapshotBlock = uint64(block.number);
        p.votableAt = _votableSupply();
        p.param = param;
        p.newValue = newValue;

        emit ProposalCreated(id, msg.sender, param, newValue);
        description;
    }

    /// @notice Propose spending from a community EVA pool (1 = airdrop, 2 = treasury, 3 = ecosystem).
    function proposeSpend(uint8 pool, address to, uint256 amount, string calldata description)
        external
        returns (uint256 id)
    {
        if (pool < 1 || pool > 3) revert BadProposal();
        if (to == address(0) || amount == 0) revert ZeroAmount();
        if (amount > _spendPoolLeft(pool)) revert PoolExhausted();
        if (_votingPowerOf(msg.sender) < PROPOSE_THRESHOLD) revert NoPower();

        id = ++proposalCount;
        Proposal storage p = proposals[id];
        p.createdAt = uint64(block.timestamp);
        p.voteEnd = uint64(block.timestamp + VOTING_PERIOD);
        p.eta = uint64(block.timestamp + VOTING_PERIOD + TIMELOCK_DELAY);
        p.snapshotBlock = uint64(block.number);
        p.votableAt = _votableSupply();
        p.param = 6;
        p.spendPool = pool;
        p.spendTo = to;
        p.newValue = amount;

        emit ProposalCreated(id, msg.sender, 6, amount);
        description;
    }

    function _spendPoolLeft(uint8 pool) internal view returns (uint256) {
        if (pool == 1) return AIRDROP_POOL - airdropSpent;
        if (pool == 2) return TREASURY_POOL - treasuryEVASpent;
        return ECOSYSTEM_POOL - ecosystemEVASpent;
    }

    function _validateParam(uint8 param, uint256 v) internal pure {
        if (param == 0) { if (v < BUY_TAX_MIN || v > BUY_TAX_MAX) revert ParamOutOfBounds(); }
        else if (param == 1) { if (v < SELL_TAX_MIN || v > SELL_TAX_MAX) revert ParamOutOfBounds(); }
        else if (param == 2) { if (v < MAXBUY_MIN || v > MAXBUY_MAX) revert ParamOutOfBounds(); }
        else if (param == 3) { if (v < DAILY_MIN || v > DAILY_MAX) revert ParamOutOfBounds(); }
        else if (param == 4) { if (v < BREAKER_MIN || v > BREAKER_MAX) revert ParamOutOfBounds(); }
        else { if (v == 0 || v > type(uint160).max) revert BadHub(); }
    }

    /// @notice Vote with snapshot voting power (+25% AVA IdentityNFT boost, bounded).
    function vote(uint256 id, bool support) external {
        Proposal storage p = proposals[id];
        if (p.createdAt == 0) revert BadProposal();
        if (block.timestamp > p.voteEnd) revert VotingClosed();
        if (hasVoted[id][msg.sender]) revert AlreadyVoted();
        hasVoted[id][msg.sender] = true;

        uint256 power = powerAt(msg.sender, p.snapshotBlock);
        if (power == 0) revert NoPower();
        power = (power * (10000 + _nftBoostBP(msg.sender))) / 10000;

        if (support) p.forVotes += power;
        else p.againstVotes += power;

        emit Voted(id, msg.sender, support, power);
    }

    /// @notice Execute a passed proposal after the timelock. Permissionless.
    function execute(uint256 id) external nonReentrant {
        Proposal storage p = proposals[id];
        if (p.createdAt == 0) revert BadProposal();
        if (p.executed) revert AlreadyExecuted();
        if (block.timestamp <= p.voteEnd) revert VotingClosed();
        if (block.timestamp < p.eta) revert TimelockPending();

        uint256 quorum = (p.votableAt * QUORUM_BP) / 10000;
        if (p.forVotes < quorum || p.forVotes <= p.againstVotes) revert QuorumNotReached();

        p.executed = true;
        if (p.param == 6) {
            // Community spend: re-check the pool cap at execution time.
            if (p.newValue > _spendPoolLeft(p.spendPool)) revert PoolExhausted();
            if (p.spendPool == 1) airdropSpent += p.newValue;
            else if (p.spendPool == 2) treasuryEVASpent += p.newValue;
            else ecosystemEVASpent += p.newValue;
            _transfer(address(this), p.spendTo, p.newValue);
            emit CommunitySpent(p.spendPool, p.spendTo, p.newValue);
        } else {
            _validateParam(p.param, p.newValue);
            if (p.param == 0) buyTaxBP = p.newValue;
            else if (p.param == 1) sellTaxBP = p.newValue;
            else if (p.param == 2) maxBuyTxEVA = p.newValue;
            else if (p.param == 3) maxDailyBuyUSD8 = p.newValue;
            else if (p.param == 4) breakerBP = p.newValue;
            else {
                address hub = address(uint160(p.newValue));
                engineHub = hub;
                emit EngineHubSet(hub);
            }
            emit ProposalExecuted(id, p.param, p.newValue);
        }
    }

    function proposalState(uint256 id)
        external
        view
        returns (
            uint64 voteEnd,
            uint64 eta,
            uint256 forVotes,
            uint256 againstVotes,
            bool executed,
            bool passed
        )
    {
        Proposal storage p = proposals[id];
        voteEnd = p.voteEnd;
        eta = p.eta;
        forVotes = p.forVotes;
        againstVotes = p.againstVotes;
        executed = p.executed;
        uint256 quorum = (p.votableAt * QUORUM_BP) / 10000;
        passed = p.forVotes >= quorum && p.forVotes > p.againstVotes;
    }

    /// @notice Current voting power of an account (balance + staked, counted once).
    function votingPower(address a) external view returns (uint256) {
        uint256 p = _votingPowerOf(a);
        return (p * (10000 + _nftBoostBP(a))) / 10000;
    }
}

