// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20, IERC20Metadata, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Interface for Vittagems (VGMG) token with mint capability
interface IVittagems is IERC20 {
    function mint(address to, uint256 amount) external;
}

/**
 * @title VittagemsVestingVault
 * @notice ERC4626-compliant tokenized vesting vault for the Vittagems (VGMG) ecosystem.
 * @dev Combines ERC4626 vault shares with linear vesting schedules, multi-party authorization,
 *      revocation workflows with admin approval, admin mint-and-vest capability, and direct user deposit.
 */
contract VittagemsVestingVault is ERC4626, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────────
    //                                  ROLES
    // ─────────────────────────────────────────────────────────────────────────────

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ─────────────────────────────────────────────────────────────────────────────
    //                                  ENUMS
    // ─────────────────────────────────────────────────────────────────────────────

    enum RevocationStatus {
        None,       // Normal active schedule
        Requested,  // Revocation requested, awaiting admin decision
        Approved,   // Admin approved revocation; unvested assets refunded and shares burned
        Rejected    // Admin rejected revocation request; schedule resumes normal vesting
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                                 STRUCTS
    // ─────────────────────────────────────────────────────────────────────────────

    struct VestingSchedule {
        uint256 id;
        address beneficiary;        // Beneficiary entitled to receive vested VGMG tokens
        address funder;             // Party who funded the vesting (admin/treasury or beneficiary)
        uint256 totalAssets;        // Total VGMG tokens assigned to this schedule
        uint256 totalShares;        // Vault shares allocated for this schedule (1:1 with assets)
        uint256 releasedAssets;     // Amount of VGMG tokens already claimed / withdrawn
        uint256 startTime;          // Timestamp when vesting calculation begins
        uint256 cliffDuration;      // Duration in seconds before any tokens can be claimed
        uint256 duration;           // Total vesting duration in seconds
        uint256 slicePeriodSeconds; // Interval in seconds for linear unlock increments (e.g. 1s)
        bool revocable;             // Whether this schedule is eligible for revocation requests
        RevocationStatus revocationStatus; // Current revocation lifecycle status
        uint256 revocationTime;     // Timestamp when revocation was approved
        bool initialized;           // Flag indicating schedule exists and is active
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                              STATE VARIABLES
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Counter for generating unique schedule IDs
    uint256 public nextScheduleId;

    /// @notice Mapping from schedule ID to VestingSchedule
    mapping(uint256 => VestingSchedule) public vestingSchedules;

    /// @notice Mapping from beneficiary address to an array of their schedule IDs
    mapping(address => uint256[]) private _beneficiarySchedules;

    /// @notice Mapping from beneficiary to admin to approval status for creating vesting on their behalf
    /// beneficiary => admin => isApproved
    mapping(address => mapping(address => bool)) public isApprovedForVesting;

    /// @notice Default parameters for ERC4626 standard deposit/mint calls
    uint256 public defaultVestingDuration;
    uint256 public defaultCliffDuration;
    bool public defaultRevocable;

    /// @dev Internal reentrancy/deduplication flag during explicit schedule releases
    bool private _explicitScheduleRelease;

    // ─────────────────────────────────────────────────────────────────────────────
    //                                  EVENTS
    // ─────────────────────────────────────────────────────────────────────────────

    event VestingScheduleCreated(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        address indexed funder,
        uint256 totalAssets,
        uint256 startTime,
        uint256 duration,
        uint256 cliffDuration,
        bool revocable
    );

    event AdminMintedAndVested(
        address indexed beneficiary,
        uint256 amount,
        uint256 indexed scheduleId
    );

    event AdminDepositedAndVested(
        address indexed beneficiary,
        uint256 amount,
        uint256 indexed scheduleId
    );

    event BeneficiaryVestingCreatedByAdmin(
        address indexed beneficiary,
        address indexed admin,
        uint256 amount,
        uint256 indexed scheduleId
    );

    event UserDirectDepositVested(
        address indexed user,
        uint256 amount,
        uint256 indexed scheduleId
    );

    event VestingApprovalUpdated(
        address indexed beneficiary,
        address indexed admin,
        bool approved
    );

    event RevocationRequested(
        uint256 indexed scheduleId,
        address indexed requester,
        address indexed beneficiary
    );

    event RevocationApproved(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        address indexed refundRecipient,
        uint256 vestedAmount,
        uint256 unvestedAmount
    );

    event RevocationRejected(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        address indexed admin,
        string reason
    );

    event RevocationCancelled(
        uint256 indexed scheduleId,
        address indexed caller
    );

    event TokensClaimed(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        address indexed receiver,
        uint256 amount
    );

    event DefaultVestingParamsUpdated(
        uint256 duration,
        uint256 cliffDuration,
        bool revocable
    );

    event EmergencyTokenRecovered(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    // ─────────────────────────────────────────────────────────────────────────────
    //                               CUSTOM ERRORS
    // ─────────────────────────────────────────────────────────────────────────────

    error InvalidAddress(string param);
    error ZeroAmount();
    error InvalidVestingParameters(string reason);
    error BeneficiaryApprovalRequired(address beneficiary, address admin);
    error ScheduleNotFound(uint256 scheduleId);
    error ScheduleNotRevocable(uint256 scheduleId);
    error RevocationAlreadyHandled(uint256 scheduleId, RevocationStatus status);
    error RevocationNotRequested(uint256 scheduleId);
    error ScheduleFullyClaimed(uint256 scheduleId);
    error Unauthorized(address caller);
    error InvalidClaimAmount(uint256 requested, uint256 available);
    error NoReleasableFunds(uint256 scheduleId);
    error NoReleasableFundsAcrossSchedules(address beneficiary);
    error SharesLockedInVesting(address account, uint256 attemptedTransfer, uint256 available);
    error InsufficientReleasableFunds(address owner, uint256 requested, uint256 available);
    error CannotRecoverVestingAsset();

    // ─────────────────────────────────────────────────────────────────────────────
    //                               MODIFIERS
    // ─────────────────────────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) {
            revert Unauthorized(_msgSender());
        }
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                              CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Initializes the Vittagems Vesting Vault
     * @param vgmgToken Address of the underlying VGMG ERC20 token
     * @param vaultName Name for the ERC4626 vault share token
     * @param vaultSymbol Symbol for the ERC4626 vault share token
     * @param defaultAdmin Address assigned the DEFAULT_ADMIN_ROLE
     * @param pauser Address assigned the PAUSER_ROLE
     */
    constructor(
        address vgmgToken,
        string memory vaultName,
        string memory vaultSymbol,
        address defaultAdmin,
        address pauser
    )
        ERC20(vaultName, vaultSymbol)
        ERC4626(IERC20(vgmgToken))
    {
        if (vgmgToken == address(0)) revert InvalidAddress("vgmgToken");
        if (defaultAdmin == address(0)) revert InvalidAddress("defaultAdmin");
        if (pauser == address(0)) revert InvalidAddress("pauser");

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE, pauser);

        defaultVestingDuration = 180 days;
        defaultCliffDuration = 0;
        defaultRevocable = true;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                      ADMIN VESTING CREATION & MINTING
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Admin mints VGMG tokens directly into the vesting vault and creates a vesting schedule for a beneficiary.
     * @dev Requires that this vesting contract has been granted MINTER_ROLE on the Vittagems token contract.
     * @param beneficiary The address receiving the vesting allocation and vault shares
     * @param amount The amount of VGMG tokens to mint and vest (18 decimals)
     * @param duration Vesting period duration in seconds
     * @param cliffDuration Cliff duration in seconds from start
     * @param revocable Whether the schedule can be requested for revocation
     * @return scheduleId Unique ID of the created vesting schedule
     */
    function adminMintAndVest(
        address beneficiary,
        uint256 amount,
        uint256 duration,
        uint256 cliffDuration,
        bool revocable
    ) external onlyAdmin nonReentrant whenNotPaused returns (uint256 scheduleId) {
        if (beneficiary == address(0)) revert InvalidAddress("beneficiary");
        if (amount == 0) revert ZeroAmount();
        if (duration == 0) revert InvalidVestingParameters("duration cannot be 0");
        if (cliffDuration > duration) revert InvalidVestingParameters("cliff exceeds duration");

        // Mint underlying VGMG tokens into this contract
        IVittagems(asset()).mint(address(this), amount);

        // Create schedule
        scheduleId = _createSchedule(
            beneficiary,
            _msgSender(),
            amount,
            block.timestamp,
            duration,
            cliffDuration,
            1,
            revocable
        );

        // Mint vault shares to beneficiary (1:1 with assets)
        _mint(beneficiary, amount);

        emit AdminMintedAndVested(beneficiary, amount, scheduleId);
        emit Deposit(_msgSender(), beneficiary, amount, amount);
    }

    /**
     * @notice Admin deposits VGMG tokens from their own balance / treasury and locks them into vesting for a beneficiary.
     * @param beneficiary The recipient of the vesting allocation
     * @param amount The amount of VGMG tokens to deposit
     * @param duration Vesting period duration in seconds
     * @param cliffDuration Cliff duration in seconds
     * @param revocable Whether the schedule is revocable
     * @return scheduleId The created schedule ID
     */
    function adminDepositAndVest(
        address beneficiary,
        uint256 amount,
        uint256 duration,
        uint256 cliffDuration,
        bool revocable
    ) external onlyAdmin nonReentrant whenNotPaused returns (uint256 scheduleId) {
        if (beneficiary == address(0)) revert InvalidAddress("beneficiary");
        if (amount == 0) revert ZeroAmount();
        if (duration == 0) revert InvalidVestingParameters("duration cannot be 0");
        if (cliffDuration > duration) revert InvalidVestingParameters("cliff exceeds duration");

        SafeERC20.safeTransferFrom(IERC20(asset()), _msgSender(), address(this), amount);

        scheduleId = _createSchedule(
            beneficiary,
            _msgSender(),
            amount,
            block.timestamp,
            duration,
            cliffDuration,
            1,
            revocable
        );

        _mint(beneficiary, amount);

        emit AdminDepositedAndVested(beneficiary, amount, scheduleId);
        emit Deposit(_msgSender(), beneficiary, amount, amount);
    }

    /**
     * @notice Admin creates a vesting schedule using funds from a beneficiary who has explicitly approved the admin.
     * @dev Beneficiary must have called `setVestingApproval(admin, true)` and approved token allowance to this contract.
     * @param beneficiary The user providing funds and receiving the vesting schedule
     * @param amount The token amount to transfer and lock into vesting
     * @param duration Vesting period duration in seconds
     * @param cliffDuration Cliff period in seconds
     * @param revocable Whether the schedule is revocable
     * @return scheduleId The created schedule ID
     */
    function adminCreateVestingFromBeneficiary(
        address beneficiary,
        uint256 amount,
        uint256 duration,
        uint256 cliffDuration,
        bool revocable
    ) external onlyAdmin nonReentrant whenNotPaused returns (uint256 scheduleId) {
        if (beneficiary == address(0)) revert InvalidAddress("beneficiary");
        if (amount == 0) revert ZeroAmount();
        if (duration == 0) revert InvalidVestingParameters("duration cannot be 0");
        if (cliffDuration > duration) revert InvalidVestingParameters("cliff exceeds duration");

        if (!isApprovedForVesting[beneficiary][_msgSender()]) {
            revert BeneficiaryApprovalRequired(beneficiary, _msgSender());
        }

        SafeERC20.safeTransferFrom(IERC20(asset()), beneficiary, address(this), amount);

        scheduleId = _createSchedule(
            beneficiary,
            beneficiary,
            amount,
            block.timestamp,
            duration,
            cliffDuration,
            1,
            revocable
        );

        _mint(beneficiary, amount);

        emit BeneficiaryVestingCreatedByAdmin(beneficiary, _msgSender(), amount, scheduleId);
        emit Deposit(_msgSender(), beneficiary, amount, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                          BENEFICIARY APPROVALS
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Allows a beneficiary to grant or revoke permission for an admin to set up vesting schedules using their tokens.
     * @param admin The admin address being authorized
     * @param approved True to approve, false to revoke approval
     */
    function setVestingApproval(address admin, bool approved) external {
        if (admin == address(0)) revert InvalidAddress("admin");
        isApprovedForVesting[_msgSender()][admin] = approved;
        emit VestingApprovalUpdated(_msgSender(), admin, approved);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                           USER DIRECT DEPOSIT
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Allows any user to directly deposit VGMG tokens and create a customized vesting schedule for themselves.
     * @param amount The VGMG amount to deposit
     * @param duration The vesting duration in seconds
     * @param cliffDuration The cliff duration in seconds
     * @param revocable Whether the user wants the schedule to be eligible for revocation requests
     * @return scheduleId The created schedule ID
     */
    function depositAndVest(
        uint256 amount,
        uint256 duration,
        uint256 cliffDuration,
        bool revocable
    ) external nonReentrant whenNotPaused returns (uint256 scheduleId) {
        if (amount == 0) revert ZeroAmount();
        if (duration == 0) revert InvalidVestingParameters("duration cannot be 0");
        if (cliffDuration > duration) revert InvalidVestingParameters("cliff exceeds duration");

        SafeERC20.safeTransferFrom(IERC20(asset()), _msgSender(), address(this), amount);

        scheduleId = _createSchedule(
            _msgSender(),
            _msgSender(),
            amount,
            block.timestamp,
            duration,
            cliffDuration,
            1,
            revocable
        );

        _mint(_msgSender(), amount);

        emit UserDirectDepositVested(_msgSender(), amount, scheduleId);
        emit Deposit(_msgSender(), _msgSender(), amount, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                        REVOCATION REQUEST & APPROVAL
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Beneficiary or funder requests revocation of an active revocable vesting schedule.
     * @dev Puts schedule into `Requested` status. Funds are NOT revoked until an admin approves.
     * @param scheduleId The schedule ID to request revocation for
     */
    function requestRevocation(uint256 scheduleId) external nonReentrant whenNotPaused {
        VestingSchedule storage s = vestingSchedules[scheduleId];
        if (!s.initialized) revert ScheduleNotFound(scheduleId);
        if (!s.revocable) revert ScheduleNotRevocable(scheduleId);
        if (_msgSender() != s.beneficiary && _msgSender() != s.funder && !hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) {
            revert Unauthorized(_msgSender());
        }
        if (s.revocationStatus != RevocationStatus.None) {
            revert RevocationAlreadyHandled(scheduleId, s.revocationStatus);
        }
        if (s.releasedAssets >= s.totalAssets) {
            revert ScheduleFullyClaimed(scheduleId);
        }

        s.revocationStatus = RevocationStatus.Requested;
        emit RevocationRequested(scheduleId, _msgSender(), s.beneficiary);
    }

    /**
     * @notice Admin approves a requested revocation.
     * @dev Freezes vesting at block.timestamp. Vested amount is retained for the beneficiary.
     *      Unvested assets are refunded to the original funder (or beneficiary if self-funded),
     *      and corresponding unvested vault shares are burned from the beneficiary.
     * @param scheduleId The ID of the schedule with a pending revocation request
     */
    function approveRevocation(uint256 scheduleId) external onlyAdmin nonReentrant whenNotPaused {
        VestingSchedule storage s = vestingSchedules[scheduleId];
        if (!s.initialized) revert ScheduleNotFound(scheduleId);
        if (s.revocationStatus != RevocationStatus.Requested) {
            revert RevocationNotRequested(scheduleId);
        }

        uint256 vested = vestedAmount(scheduleId);
        uint256 total = s.totalAssets;
        uint256 unvested = total > vested ? total - vested : 0;

        s.revocationStatus = RevocationStatus.Approved;
        s.revocationTime = block.timestamp;
        s.totalAssets = vested;
        s.totalShares = vested;

        // Burn the unvested vault shares from beneficiary
        if (unvested > 0) {
            _burn(s.beneficiary, unvested);
        }

        // Determine refund recipient for unvested VGMG
        address refundRecipient = (s.funder == s.beneficiary) ? s.beneficiary : s.funder;

        if (unvested > 0) {
            SafeERC20.safeTransfer(IERC20(asset()), refundRecipient, unvested);
        }

        emit RevocationApproved(scheduleId, s.beneficiary, refundRecipient, vested, unvested);
    }

    /**
     * @notice Admin rejects a revocation request, allowing the schedule to continue its normal vesting progression.
     * @param scheduleId The ID of the schedule
     * @param reason Description/reason for rejection
     */
    function rejectRevocation(uint256 scheduleId, string calldata reason) external onlyAdmin whenNotPaused {
        VestingSchedule storage s = vestingSchedules[scheduleId];
        if (!s.initialized) revert ScheduleNotFound(scheduleId);
        if (s.revocationStatus != RevocationStatus.Requested) {
            revert RevocationNotRequested(scheduleId);
        }

        s.revocationStatus = RevocationStatus.None;
        emit RevocationRejected(scheduleId, s.beneficiary, _msgSender(), reason);
    }

    /**
     * @notice Beneficiary or funder cancels a pending revocation request before admin review.
     * @param scheduleId The ID of the schedule
     */
    function cancelRevocationRequest(uint256 scheduleId) external nonReentrant whenNotPaused {
        VestingSchedule storage s = vestingSchedules[scheduleId];
        if (!s.initialized) revert ScheduleNotFound(scheduleId);
        if (s.revocationStatus != RevocationStatus.Requested) {
            revert RevocationNotRequested(scheduleId);
        }
        if (_msgSender() != s.beneficiary && _msgSender() != s.funder && !hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) {
            revert Unauthorized(_msgSender());
        }

        s.revocationStatus = RevocationStatus.None;
        emit RevocationCancelled(scheduleId, _msgSender());
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                           REDEMPTION & CLAIMS
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Claim a specific amount of vested VGMG tokens from a specific vesting schedule.
     * @param scheduleId The ID of the vesting schedule
     * @param amount The amount of tokens to claim
     * @param receiver The address receiving the claimed VGMG tokens
     * @return claimed The amount of tokens actually claimed
     */
    function claim(
        uint256 scheduleId,
        uint256 amount,
        address receiver
    ) public nonReentrant whenNotPaused returns (uint256 claimed) {
        if (receiver == address(0)) revert InvalidAddress("receiver");
        VestingSchedule storage schedule = vestingSchedules[scheduleId];
        if (!schedule.initialized) revert ScheduleNotFound(scheduleId);
        if (_msgSender() != schedule.beneficiary) revert Unauthorized(_msgSender());

        uint256 releasable = releasableAmount(scheduleId);
        if (amount == 0 || amount > releasable) revert InvalidClaimAmount(amount, releasable);

        schedule.releasedAssets += amount;

        _explicitScheduleRelease = true;
        _withdraw(_msgSender(), receiver, _msgSender(), amount, amount);
        _explicitScheduleRelease = false;

        emit TokensClaimed(scheduleId, _msgSender(), receiver, amount);
        return amount;
    }

    /**
     * @notice Claim all currently releasable VGMG tokens for a given schedule.
     * @param scheduleId The ID of the vesting schedule
     * @param receiver The address to send claimed tokens to
     * @return claimed The amount of tokens claimed
     */
    function claimAll(uint256 scheduleId, address receiver) external returns (uint256 claimed) {
        uint256 releasable = releasableAmount(scheduleId);
        if (releasable == 0) revert NoReleasableFunds(scheduleId);
        return claim(scheduleId, releasable, receiver);
    }

    /**
     * @notice Claim all currently releasable VGMG tokens across all schedules belonging to caller.
     * @param receiver The destination address for the claimed tokens
     * @return totalClaimed The total amount of tokens claimed
     */
    function claimAllSchedules(address receiver) external nonReentrant whenNotPaused returns (uint256 totalClaimed) {
        if (receiver == address(0)) revert InvalidAddress("receiver");
        uint256[] storage scheduleIds = _beneficiarySchedules[_msgSender()];

        for (uint256 i = 0; i < scheduleIds.length; i++) {
            uint256 schedId = scheduleIds[i];
            uint256 releasable = releasableAmount(schedId);
            if (releasable > 0) {
                vestingSchedules[schedId].releasedAssets += releasable;
                totalClaimed += releasable;
                emit TokensClaimed(schedId, _msgSender(), receiver, releasable);
            }
        }

        if (totalClaimed == 0) revert NoReleasableFundsAcrossSchedules(_msgSender());

        _explicitScheduleRelease = true;
        _withdraw(_msgSender(), receiver, _msgSender(), totalClaimed, totalClaimed);
        _explicitScheduleRelease = false;

        return totalClaimed;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                        ERC4626 OVERRIDES & COMPLIANCE
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Standard ERC4626 deposit - creates a vesting schedule using default vault parameters.
     */
    function deposit(uint256 assets, address receiver) public virtual override nonReentrant whenNotPaused returns (uint256) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress("receiver");

        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);

        _createSchedule(
            receiver,
            _msgSender(),
            assets,
            block.timestamp,
            defaultVestingDuration,
            defaultCliffDuration,
            1,
            defaultRevocable
        );

        return shares;
    }

    /**
     * @notice Standard ERC4626 mint - creates a vesting schedule using default vault parameters.
     */
    function mint(uint256 shares, address receiver) public virtual override nonReentrant whenNotPaused returns (uint256) {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress("receiver");

        uint256 assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);

        _createSchedule(
            receiver,
            _msgSender(),
            assets,
            block.timestamp,
            defaultVestingDuration,
            defaultCliffDuration,
            1,
            defaultRevocable
        );

        return assets;
    }

    /**
     * @notice Maximum redeemable shares for an owner, strictly capped by their vested & unreleased shares.
     */
    function maxRedeem(address owner) public view virtual override returns (uint256) {
        if (paused()) return 0;
        uint256 releasable = totalReleasableShares(owner);
        uint256 balance = balanceOf(owner);
        return releasable > balance ? balance : releasable;
    }

    /**
     * @notice Maximum withdrawable assets for an owner, strictly capped by their vested & unreleased assets.
     */
    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        return previewRedeem(maxRedeem(owner));
    }

    /**
     * @dev Overrides internal `_withdraw` to automatically release from oldest schedules when standard ERC4626
     *      withdraw or redeem is invoked.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        if (!_explicitScheduleRelease) {
            _releaseFromSchedules(owner, assets);
        }
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /**
     * @dev Overrides token transfer hook to ensure unvested shares cannot be transferred between users.
     */
    function _update(address from, address to, uint256 value) internal virtual override(ERC20) {
        if (from != address(0) && to != address(0)) {
            uint256 locked = totalLockedShares(from);
            uint256 balance = balanceOf(from);
            uint256 unlocked = balance > locked ? balance - locked : 0;
            if (value > unlocked) {
                revert SharesLockedInVesting(from, value, unlocked);
            }
        }
        super._update(from, to, value);
    }

    /**
     * @dev Exact 1:1 asset-to-share conversion for deterministic vesting representation.
     */
    function _convertToShares(uint256 assets, Math.Rounding) internal view virtual override returns (uint256) {
        return assets;
    }

    /**
     * @dev Exact 1:1 share-to-asset conversion for deterministic vesting representation.
     */
    function _convertToAssets(uint256 shares, Math.Rounding) internal view virtual override returns (uint256) {
        return shares;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                           CALCULATION & VIEWS
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Calculates the total amount of vested VGMG tokens for a schedule up to the current block timestamp.
     * @param scheduleId The ID of the vesting schedule
     * @return The amount of tokens that have vested
     */
    function vestedAmount(uint256 scheduleId) public view returns (uint256) {
        VestingSchedule storage s = vestingSchedules[scheduleId];
        if (!s.initialized) return 0;

        // If revocation was approved, the totalAssets of the schedule were locked to the exact vested amount
        if (s.revocationStatus == RevocationStatus.Approved) {
            return s.totalAssets;
        }

        uint256 currentTime = block.timestamp;

        if (currentTime < s.startTime + s.cliffDuration) {
            return 0;
        }

        if (currentTime >= s.startTime + s.duration) {
            return s.totalAssets;
        }

        uint256 timeFromStart = currentTime - s.startTime;
        uint256 secondsPerSlice = s.slicePeriodSeconds;
        uint256 vestedSlicePeriods = timeFromStart / secondsPerSlice;
        uint256 vestedSeconds = vestedSlicePeriods * secondsPerSlice;

        return (s.totalAssets * vestedSeconds) / s.duration;
    }

    /**
     * @notice Calculates the amount of tokens currently releasable (vested minus already claimed) for a schedule.
     * @param scheduleId The ID of the schedule
     * @return The amount of tokens available for immediate claim
     */
    function releasableAmount(uint256 scheduleId) public view returns (uint256) {
        VestingSchedule storage s = vestingSchedules[scheduleId];
        if (!s.initialized) return 0;
        uint256 vested = vestedAmount(scheduleId);
        if (vested > s.releasedAssets) {
            return vested - s.releasedAssets;
        }
        return 0;
    }

    /**
     * @notice Total vested shares for an account across all their vesting schedules.
     */
    function totalVestedShares(address account) public view returns (uint256 totalVested) {
        uint256[] storage ids = _beneficiarySchedules[account];
        for (uint256 i = 0; i < ids.length; i++) {
            totalVested += vestedAmount(ids[i]);
        }
    }

    /**
     * @notice Total locked (unvested) shares for an account across all active schedules.
     */
    function totalLockedShares(address account) public view returns (uint256 totalLocked) {
        uint256[] storage ids = _beneficiarySchedules[account];
        for (uint256 i = 0; i < ids.length; i++) {
            VestingSchedule storage s = vestingSchedules[ids[i]];
            if (s.initialized && s.revocationStatus != RevocationStatus.Approved) {
                uint256 vested = vestedAmount(ids[i]);
                if (s.totalShares > vested) {
                    totalLocked += (s.totalShares - vested);
                }
            }
        }
    }

    /**
     * @notice Total releasable (vested but unredeemed) shares for an account across all schedules.
     */
    function totalReleasableShares(address account) public view returns (uint256 totalReleasable) {
        uint256[] storage ids = _beneficiarySchedules[account];
        for (uint256 i = 0; i < ids.length; i++) {
            totalReleasable += releasableAmount(ids[i]);
        }
    }

    /**
     * @notice Returns complete schedule details for a given schedule ID.
     */
    function getSchedule(uint256 scheduleId) external view returns (VestingSchedule memory) {
        VestingSchedule memory s = vestingSchedules[scheduleId];
        if (!s.initialized) revert ScheduleNotFound(scheduleId);
        return s;
    }

    /**
     * @notice Returns array of all schedule IDs belonging to a beneficiary.
     */
    function getBeneficiarySchedules(address beneficiary) external view returns (uint256[] memory) {
        return _beneficiarySchedules[beneficiary];
    }

    /**
     * @notice Returns total number of schedules created for a beneficiary.
     */
    function getBeneficiaryScheduleCount(address beneficiary) external view returns (uint256) {
        return _beneficiarySchedules[beneficiary].length;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                            ADMIN CONFIGURATION
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @notice Updates the default vesting parameters applied to standard ERC4626 deposit/mint calls.
     * @param duration Vesting duration in seconds
     * @param cliffDuration Cliff duration in seconds
     * @param revocable Whether default schedules are revocable
     */
    function setDefaultVestingParams(
        uint256 duration,
        uint256 cliffDuration,
        bool revocable
    ) external onlyAdmin {
        if (duration == 0) revert InvalidVestingParameters("duration cannot be 0");
        if (cliffDuration > duration) revert InvalidVestingParameters("cliff exceeds duration");

        defaultVestingDuration = duration;
        defaultCliffDuration = cliffDuration;
        defaultRevocable = revocable;

        emit DefaultVestingParamsUpdated(duration, cliffDuration, revocable);
    }

    /**
     * @notice Pauses contract operations
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses contract operations
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Recovers erroneously sent ERC20 tokens. Cannot recover the underlying VGMG token.
     * @param token Address of the token to recover
     * @param to Destination address
     * @param amount Amount to recover
     */
    function recoverERC20(address token, address to, uint256 amount) external onlyAdmin {
        if (token == asset()) revert CannotRecoverVestingAsset();
        if (to == address(0)) revert InvalidAddress("to");
        if (amount == 0) revert ZeroAmount();

        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit EmergencyTokenRecovered(token, to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //                           INTERNAL HELPERS
    // ─────────────────────────────────────────────────────────────────────────────

    /**
     * @dev Internal schedule creator
     */
    function _createSchedule(
        address beneficiary,
        address funder,
        uint256 amount,
        uint256 startTime,
        uint256 duration,
        uint256 cliffDuration,
        uint256 slicePeriodSeconds,
        bool revocable
    ) internal returns (uint256 scheduleId) {
        if (slicePeriodSeconds == 0) slicePeriodSeconds = 1;

        scheduleId = nextScheduleId++;

        vestingSchedules[scheduleId] = VestingSchedule({
            id: scheduleId,
            beneficiary: beneficiary,
            funder: funder,
            totalAssets: amount,
            totalShares: amount,
            releasedAssets: 0,
            startTime: startTime,
            cliffDuration: cliffDuration,
            duration: duration,
            slicePeriodSeconds: slicePeriodSeconds,
            revocable: revocable,
            revocationStatus: RevocationStatus.None,
            revocationTime: 0,
            initialized: true
        });

        _beneficiarySchedules[beneficiary].push(scheduleId);

        emit VestingScheduleCreated(
            scheduleId,
            beneficiary,
            funder,
            amount,
            startTime,
            duration,
            cliffDuration,
            revocable
        );
    }

    /**
     * @dev Releases `amountToRelease` from the oldest active schedules belonging to `owner`.
     */
    function _releaseFromSchedules(address owner, uint256 amountToRelease) internal {
        uint256 remaining = amountToRelease;
        uint256[] storage scheduleIds = _beneficiarySchedules[owner];

        for (uint256 i = 0; i < scheduleIds.length && remaining > 0; i++) {
            uint256 schedId = scheduleIds[i];
            VestingSchedule storage schedule = vestingSchedules[schedId];
            if (!schedule.initialized) continue;

            uint256 releasable = releasableAmount(schedId);
            if (releasable > 0) {
                uint256 toTake = remaining < releasable ? remaining : releasable;
                schedule.releasedAssets += toTake;
                remaining -= toTake;
                emit TokensClaimed(schedId, owner, _msgSender(), toTake);
            }
        }

        if (remaining > 0) {
            revert InsufficientReleasableFunds(owner, amountToRelease, amountToRelease - remaining);
        }
    }
}
