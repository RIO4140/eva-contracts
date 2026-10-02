// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title EWA Core — minimal token ledger
/// @notice The original token: a tiny, auditable core. ERC20 ledger +
///         capped minting + burning + admin/minter roles. NOTHING else.
///
///         Design rules (learned from EVA_Core's failure):
///         1. No self-defeating logic: every state transition is tested
///            to persist after the transaction completes.
///         2. No market, no taxes, no staking, no governance, no breaker,
///            no oracles, no allocation pools — those are satellites.
///         3. NO MIGRATION — by explicit order. No migration functions,
///            constants, or pools exist in this contract.
///         4. Narrow interface: satellites depend on standard ERC20 only.
///         5. Two-step admin transfer: no fat-finger lockout.
///
///         Satellites that need market/governance/staking must implement
///         them as separate contracts holding EWA, never inside this core.
contract EWA_Core {
    // ------------------------------------------------------------------
    // Metadata / supply
    // ------------------------------------------------------------------
    string public constant name = "EWA";
    string public constant symbol = "EWA";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    uint256 public immutable MAX_SUPPLY;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ------------------------------------------------------------------
    // Roles
    // ------------------------------------------------------------------
    /// @notice Sole admin. Can grant/revoke minters and rotate adminship.
    address public admin;
    /// @notice Pending admin (two-step rotation).
    address public pendingAdmin;
    /// @notice Addresses allowed to mint (and burnFrom) within the cap.
    mapping(address => bool) public minters;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event MinterGranted(address indexed account);
    event MinterRevoked(address indexed account);
    event AdminProposed(address indexed newAdmin);
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------
    error ZeroAddress();
    error NotAdmin();
    error NotMinter();
    error NotPendingAdmin();
    error CapExceeded();
    error InsufficientBalance();
    error InsufficientAllowance();

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    /// @param maxSupply_ Hard cap on total supply (immutable). Must be > 0.
    /// @dev Deployer becomes the first admin. No tokens are minted here;
    ///      initial distribution is explicit mint() calls by the admin
    ///      (or addresses the admin grants minter to).
    constructor(uint256 maxSupply_) {
        if (maxSupply_ == 0) revert CapExceeded();
        MAX_SUPPLY = maxSupply_;
        admin = msg.sender;
        emit AdminChanged(address(0), msg.sender);
    }

    // ------------------------------------------------------------------
    // ERC20 core
    // ------------------------------------------------------------------
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            if (a < amount) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = a - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    // ------------------------------------------------------------------
    // Mint / burn (capped)
    // ------------------------------------------------------------------
    /// @notice Mint new EWA. Minter-only. Never exceeds MAX_SUPPLY.
    function mint(address to, uint256 amount) external {
        if (!minters[msg.sender]) revert NotMinter();
        if (to == address(0)) revert ZeroAddress();
        if (totalSupply + amount > MAX_SUPPLY) revert CapExceeded();
        unchecked {
            totalSupply += amount;
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    /// @notice Burn caller's own EWA. Reduces supply permanently.
    function burn(uint256 amount) external {
        uint256 bal = balanceOf[msg.sender];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[msg.sender] = bal - amount;
            totalSupply -= amount;
        }
        emit Transfer(msg.sender, address(0), amount);
    }

    /// @notice Burn EWA from an account. Minter-only (e.g. market satellite
    ///         burning its own inventory).
    function burnFrom(address from, uint256 amount) external {
        if (!minters[msg.sender]) revert NotMinter();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    // ------------------------------------------------------------------
    // Roles
    // ------------------------------------------------------------------
    /// @notice Grant minter role. Admin-only.
    function grantMinter(address account) external {
        if (msg.sender != admin) revert NotAdmin();
        if (account == address(0)) revert ZeroAddress();
        minters[account] = true;
        emit MinterGranted(account);
    }

    /// @notice Revoke minter role. Admin-only.
    function revokeMinter(address account) external {
        if (msg.sender != admin) revert NotAdmin();
        minters[account] = false;
        emit MinterRevoked(account);
    }

    /// @notice Propose a new admin. Admin-only. Two-step: the candidate
    ///         must call acceptAdmin() — no fat-finger lockout.
    function proposeAdmin(address newAdmin) external {
        if (msg.sender != admin) revert NotAdmin();
        if (newAdmin == address(0)) revert ZeroAddress();
        pendingAdmin = newAdmin;
        emit AdminProposed(newAdmin);
    }

    /// @notice Accept a pending adminship. Candidate-only.
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        address old = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminChanged(old, admin);
    }
}
