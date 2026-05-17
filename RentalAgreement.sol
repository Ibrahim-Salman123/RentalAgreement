// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  RentalAgreement
 * @author Your Name
 * @notice Trustless rental contract between a landlord and tenant.
 *         Tenant pays a security deposit + monthly rent on-chain.
 *         Landlord can claim unpaid rent; tenant claims deposit refund
 *         at lease end if no deductions are raised within a grace period.
 * @dev    Designed for EVM-compatible chains (Ethereum, Polygon, Arbitrum, Base).
 *         Follows Checks-Effects-Interactions; no reentrancy vulnerabilities.
 */
contract RentalAgreement {

    // ─────────────────────────────────────────────
    //  TYPES
    // ─────────────────────────────────────────────

    enum LeaseState {
        Active,
        Ended,
        Disputed,
        Terminated
    }

    struct Deduction {
        string  reason;         // e.g. "Broken window repair"
        uint256 amount;         // wei
        string  evidenceIpfs;   // IPFS CID of photo/invoice
        bool    disputed;
    }

    struct Lease {
        address payable landlord;
        address payable tenant;
        uint256         monthlyRent;       // wei per month
        uint256         depositAmount;     // wei (held until lease ends)
        uint256         leaseStartTime;
        uint256         leaseEndTime;
        uint256         nextRentDue;       // unix timestamp
        uint256         depositBalance;    // remaining deposit after deductions
        LeaseState      state;
        string          propertyIpfsHash;  // IPFS CID of property/lease description
        Deduction[]     deductions;
        uint256         lastRentPaidAt;
    }

    // ─────────────────────────────────────────────
    //  STATE
    // ─────────────────────────────────────────────

    uint256 public leaseCount;
    mapping(uint256 => Lease) private _leases;

    /// @notice Grace period (seconds) after lease end before deposit auto-releases.
    uint256 public constant DEDUCTION_GRACE_PERIOD = 7 days;
    /// @notice Late fee charged per day overdue (in basis points of monthly rent).
    uint256 public constant LATE_FEE_BPS_PER_DAY   = 100; // 1% per day
    uint256 public constant SECONDS_PER_MONTH       = 30 days;

    // ─────────────────────────────────────────────
    //  EVENTS
    // ─────────────────────────────────────────────

    event LeaseCreated(
        uint256 indexed id,
        address indexed landlord,
        address indexed tenant,
        uint256 monthlyRent,
        uint256 depositAmount,
        uint256 leaseEndTime
    );
    event DepositPaid(uint256 indexed id, address indexed tenant, uint256 amount);
    event RentPaid(uint256 indexed id, address indexed tenant, uint256 amount, uint256 period);
    event DeductionRaised(uint256 indexed id, uint256 deductionIndex, uint256 amount, string reason);
    event DeductionDisputed(uint256 indexed id, uint256 deductionIndex);
    event DepositRefunded(uint256 indexed id, address indexed tenant, uint256 amount);
    event LandlordWithdrew(uint256 indexed id, uint256 amount);
    event LeaseTerminated(uint256 indexed id, address by);

    // ─────────────────────────────────────────────
    //  ERRORS
    // ─────────────────────────────────────────────

    error Unauthorized();
    error InvalidState(LeaseState current);
    error DepositAlreadyPaid();
    error DepositNotPaid();
    error RentNotDueYet();
    error IncorrectAmount(uint256 expected, uint256 sent);
    error LeaseNotEnded();
    error GracePeriodActive();
    error InsufficientDeposit();
    error TransferFailed();
    error ZeroAddress();
    error InvalidDuration();

    // ─────────────────────────────────────────────
    //  MODIFIERS
    // ─────────────────────────────────────────────

    modifier onlyLandlord(uint256 id) {
        if (msg.sender != _leases[id].landlord) revert Unauthorized();
        _;
    }

    modifier onlyTenant(uint256 id) {
        if (msg.sender != _leases[id].tenant) revert Unauthorized();
        _;
    }

    modifier onlyParty(uint256 id) {
        Lease storage l = _leases[id];
        if (msg.sender != l.landlord && msg.sender != l.tenant) revert Unauthorized();
        _;
    }

    modifier inState(uint256 id, LeaseState required) {
        if (_leases[id].state != required) revert InvalidState(_leases[id].state);
        _;
    }

    // ─────────────────────────────────────────────
    //  EXTERNAL FUNCTIONS
    // ─────────────────────────────────────────────

    /**
     * @notice Landlord creates a lease agreement.
     * @param  tenant            Wallet address of the tenant.
     * @param  monthlyRent       Rent amount in wei per month.
     * @param  depositAmount     Security deposit in wei.
     * @param  leaseDurationDays Length of the lease in days.
     * @param  propertyIpfsHash  IPFS CID of the property description / lease PDF.
     * @return id                Unique lease identifier.
     */
    function createLease(
        address payable tenant,
        uint256         monthlyRent,
        uint256         depositAmount,
        uint256         leaseDurationDays,
        string calldata propertyIpfsHash
    ) external returns (uint256 id) {
        if (tenant == address(0)) revert ZeroAddress();
        if (leaseDurationDays < 30) revert InvalidDuration();
        require(monthlyRent > 0 && depositAmount > 0, "Amounts must be > 0");

        id = leaseCount++;
        Lease storage l = _leases[id];

        l.landlord         = payable(msg.sender);
        l.tenant           = tenant;
        l.monthlyRent      = monthlyRent;
        l.depositAmount    = depositAmount;
        l.leaseStartTime   = block.timestamp;
        l.leaseEndTime     = block.timestamp + (leaseDurationDays * 1 days);
        l.nextRentDue      = block.timestamp + SECONDS_PER_MONTH;
        l.depositBalance   = 0;
        l.state            = LeaseState.Active;
        l.propertyIpfsHash = propertyIpfsHash;

        emit LeaseCreated(id, msg.sender, tenant, monthlyRent, depositAmount, l.leaseEndTime);
    }

    /**
     * @notice Tenant pays the security deposit to activate the lease.
     * @param  id Lease identifier.
     */
    function payDeposit(uint256 id)
        external payable
        onlyTenant(id)
        inState(id, LeaseState.Active)
    {
        Lease storage l = _leases[id];
        if (l.depositBalance > 0) revert DepositAlreadyPaid();
        if (msg.value != l.depositAmount)
            revert IncorrectAmount(l.depositAmount, msg.value);

        l.depositBalance = msg.value;

        emit DepositPaid(id, msg.sender, msg.value);
    }

    /**
     * @notice Tenant pays monthly rent. Calculates late fees if overdue.
     * @param  id Lease identifier.
     */
    function payRent(uint256 id)
        external payable
        onlyTenant(id)
        inState(id, LeaseState.Active)
    {
        Lease storage l = _leases[id];
        if (l.depositBalance == 0) revert DepositNotPaid();
        if (block.timestamp < l.nextRentDue - SECONDS_PER_MONTH)
            revert RentNotDueYet();

        uint256 due = l.monthlyRent;

        // Add late fees if overdue
        if (block.timestamp > l.nextRentDue) {
            uint256 daysLate  = (block.timestamp - l.nextRentDue) / 1 days;
            uint256 lateFee   = (l.monthlyRent * LATE_FEE_BPS_PER_DAY * daysLate) / 10_000;
            due += lateFee;
        }

        if (msg.value != due) revert IncorrectAmount(due, msg.value);

        l.lastRentPaidAt  = block.timestamp;
        l.nextRentDue    += SECONDS_PER_MONTH;

        // Forward rent immediately to landlord
        _safeTransfer(l.landlord, msg.value);

        emit RentPaid(id, msg.sender, msg.value, l.nextRentDue - SECONDS_PER_MONTH);
    }

    /**
     * @notice Landlord raises a deposit deduction claim after lease ends.
     * @param  id            Lease identifier.
     * @param  amount        Wei to deduct from deposit.
     * @param  reason        Human-readable reason.
     * @param  evidenceIpfs  IPFS CID of photos/invoices.
     */
    function raiseDeduction(
        uint256 id,
        uint256 amount,
        string calldata reason,
        string calldata evidenceIpfs
    ) external onlyLandlord(id) {
        Lease storage l = _leases[id];
        if (block.timestamp < l.leaseEndTime) revert LeaseNotEnded();
        if (amount > l.depositBalance) revert InsufficientDeposit();

        l.depositBalance -= amount;

        uint256 idx = l.deductions.length;
        l.deductions.push(Deduction({
            reason:       reason,
            amount:       amount,
            evidenceIpfs: evidenceIpfs,
            disputed:     false
        }));

        // Landlord receives deduction amount immediately
        _safeTransfer(l.landlord, amount);

        emit DeductionRaised(id, idx, amount, reason);
    }

    /**
     * @notice Tenant disputes a deduction (flags for off-chain / arbitration).
     * @param  id              Lease identifier.
     * @param  deductionIndex  Which deduction to dispute.
     */
    function disputeDeduction(uint256 id, uint256 deductionIndex)
        external
        onlyTenant(id)
    {
        Lease storage l = _leases[id];
        l.deductions[deductionIndex].disputed = true;
        l.state = LeaseState.Disputed;

        emit DeductionDisputed(id, deductionIndex);
    }

    /**
     * @notice Tenant claims remaining deposit after grace period expires.
     * @param  id Lease identifier.
     */
    function claimDepositRefund(uint256 id)
        external
        onlyTenant(id)
    {
        Lease storage l = _leases[id];
        if (block.timestamp < l.leaseEndTime) revert LeaseNotEnded();
        if (block.timestamp < l.leaseEndTime + DEDUCTION_GRACE_PERIOD)
            revert GracePeriodActive();

        uint256 refund   = l.depositBalance;
        l.depositBalance = 0;
        l.state          = LeaseState.Ended;

        if (refund > 0) {
            _safeTransfer(l.tenant, refund);
        }

        emit DepositRefunded(id, msg.sender, refund);
    }

    /**
     * @notice Either party terminates the lease early (mutual agreement implied by both signing).
     * @param  id Lease identifier.
     */
    function terminateLease(uint256 id)
        external
        onlyParty(id)
        inState(id, LeaseState.Active)
    {
        _leases[id].state = LeaseState.Terminated;
        emit LeaseTerminated(id, msg.sender);
    }

    // ─────────────────────────────────────────────
    //  VIEW FUNCTIONS
    // ─────────────────────────────────────────────

    /// @notice Current rent due including any late fees.
    function currentRentDue(uint256 id) external view returns (uint256 due) {
        Lease storage l = _leases[id];
        due = l.monthlyRent;
        if (block.timestamp > l.nextRentDue) {
            uint256 daysLate = (block.timestamp - l.nextRentDue) / 1 days;
            due += (l.monthlyRent * LATE_FEE_BPS_PER_DAY * daysLate) / 10_000;
        }
    }

    /// @notice Returns lease summary.
    function getLease(uint256 id)
        external view
        returns (
            address landlord,
            address tenant,
            uint256 monthlyRent,
            uint256 depositAmount,
            uint256 depositBalance,
            uint256 leaseEndTime,
            uint256 nextRentDue,
            LeaseState state,
            string memory propertyIpfsHash
        )
    {
        Lease storage l = _leases[id];
        return (
            l.landlord,
            l.tenant,
            l.monthlyRent,
            l.depositAmount,
            l.depositBalance,
            l.leaseEndTime,
            l.nextRentDue,
            l.state,
            l.propertyIpfsHash
        );
    }

    /// @notice Returns all deductions for a lease.
    function getDeductions(uint256 id) external view returns (Deduction[] memory) {
        return _leases[id].deductions;
    }

    // ─────────────────────────────────────────────
    //  INTERNAL
    // ─────────────────────────────────────────────

    function _safeTransfer(address payable to, uint256 amount) internal {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
