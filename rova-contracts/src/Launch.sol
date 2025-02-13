// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.22;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlEnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    CancelParticipationRequest,
    ClaimRefundRequest,
    CurrencyConfig,
    LaunchGroupSettings,
    LaunchGroupStatus,
    ParticipationInfo,
    ParticipationRequest,
    UpdateParticipationRequest
} from "./Types.sol";

/**
 * @title Rova Launch Contract
 * @notice Main launch contract that manages state and launch groups for Rova token sale launches
 */
contract Launch is
    Initializable,
    AccessControlEnumerableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Manager role for managing launch group settings
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice Withdrawal role for managing withdrawal address
    bytes32 public constant WITHDRAWAL_ROLE = keccak256("WITHDRAWAL_ROLE");

    /// @notice Operator role for performing automated operations like selecting winners
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Signer role for generating signatures to be verified by the contract
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    /// @notice Launch identifier
    bytes32 public launchId;

    /// @notice Address for withdrawing funds
    address public withdrawalAddress;

    /// @notice Decimals for the launch token
    /// @dev This is used to calculate currency payment amount conversions
    uint8 public tokenDecimals;

    /// @notice Launch group identifiers
    EnumerableSet.Bytes32Set internal _launchGroups;

    /// @notice Launch group settings
    mapping(bytes32 => LaunchGroupSettings) public launchGroupSettings;

    /// @notice User participation information for each launch group
    mapping(bytes32 => ParticipationInfo) public launchGroupParticipations;

    /// @notice Launch group accepted payment currencies to their config
    mapping(bytes32 => mapping(address => CurrencyConfig)) internal _launchGroupCurrencies;

    /// @notice Total tokens sold for each launch group
    /// @dev This only tracks finalized participations and is used to make sure the total token allocation for each launch group is not exceeded
    EnumerableMap.Bytes32ToUintMap internal _tokensSoldByLaunchGroup;

    /// @notice Total tokens requested per user for each launch group
    /// @dev This is used to make sure users are within the min/max token per user allocation for each launch group
    mapping(bytes32 => EnumerableMap.Bytes32ToUintMap) internal _userTokensByLaunchGroup;

    /// @notice Total finalized deposits for each launch group by currency
    /// @dev This keeps track of the total amount that can be withdrawn per currency
    EnumerableMap.AddressToUintMap internal _withdrawableAmountByCurrency;

    error InvalidRequest();
    error InvalidCurrency(bytes32 launchGroupId, address currency);
    error InvalidCurrencyAmount(bytes32 launchGroupId, address currency, uint256 currencyAmount);
    error InvalidSignature();
    error ExpiredRequest(uint256 requestExpiresAt, uint256 currentTime);
    error ParticipationAlreadyExists(bytes32 launchParticipationId);
    error MaxTokenAllocationReached(bytes32 launchGroupId);
    error MinUserTokenAllocationNotReached(
        bytes32 launchGroupId, bytes32 userId, uint256 currTokenAmount, uint256 requestedTokenAmount
    );
    error MaxUserTokenAllocationReached(
        bytes32 launchGroupId, bytes32 userId, uint256 currTokenAmount, uint256 requestedTokenAmount
    );
    error MaxUserParticipationsReached(bytes32 launchGroupId, bytes32 userId);
    error CurrencyMismatch(address expectedCurrency, address actualCurrency);
    error UserIdMismatch(bytes32 expectedUserId, bytes32 actualUserId);
    error InvalidLaunchGroupStatus(
        bytes32 launchGroupId, LaunchGroupStatus expectedStatus, LaunchGroupStatus actualStatus
    );
    error ParticipationUpdatesNotAllowed(bytes32 launchGroupId, bytes32 launchParticipationId);
    error InvalidRefundRequest(bytes32 launchParticipationId, bytes32 userId);
    error LaunchGroupFinalizesAtParticipation(bytes32 launchGroupId);
    error InvalidWinner(bytes32 launchParticipationId, bytes32 userId);
    error InvalidWithdrawalAmount(uint256 expectedBalance, uint256 actualBalance);

    /// @notice Event for launch group creation
    event LaunchGroupCreated(bytes32 indexed launchGroupId);

    /// @notice Event for launch group update
    event LaunchGroupUpdated(bytes32 indexed launchGroupId);

    /// @notice Event for launch group currency update
    event LaunchGroupCurrencyUpdated(bytes32 indexed launchGroupId, address indexed currency);

    /// @notice Event for withdrawal address update
    event WithdrawalAddressUpdated(address indexed withdrawalAddress);

    /// @notice Event for launch group status update
    event LaunchGroupStatusUpdated(bytes32 indexed launchGroupId, LaunchGroupStatus status);

    /// @notice Event for participation registration
    event ParticipationRegistered(
        bytes32 indexed launchGroupId,
        bytes32 indexed launchParticipationId,
        bytes32 indexed userId,
        address user,
        uint256 currencyAmount,
        address currency
    );

    /// @notice Event for participation update
    event ParticipationUpdated(
        bytes32 indexed launchGroupId,
        bytes32 indexed launchParticipationId,
        bytes32 indexed userId,
        address user,
        uint256 currencyAmount,
        address currency
    );

    /// @notice Event for participation cancellation
    event ParticipationCancelled(
        bytes32 indexed launchGroupId,
        bytes32 indexed launchParticipationId,
        bytes32 indexed userId,
        address user,
        uint256 currencyAmount,
        address currency
    );

    /// @notice Event for winner selection
    event WinnerSelected(
        bytes32 indexed launchGroupId, bytes32 indexed launchParticipationId, bytes32 indexed userId, address user
    );

    /// @notice Event for refund claim
    event RefundClaimed(
        bytes32 indexed launchGroupId,
        bytes32 indexed launchParticipationId,
        bytes32 indexed userId,
        address user,
        uint256 currencyAmount,
        address currency
    );

    /// @notice Event for withdrawal
    event Withdrawal(address indexed user, address indexed currency, uint256 indexed currencyAmount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _withdrawalAddress, bytes32 _launchId, address _initialAdmin, uint8 _tokenDecimals)
        external
        initializer
    {
        __AccessControlEnumerable_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        // Validate initial admin and withdrawal address are not zero
        if (_initialAdmin == address(0) || _withdrawalAddress == address(0)) {
            revert InvalidRequest();
        }

        // Grant initial admin default admin, manager, operator, and signer roles
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(MANAGER_ROLE, _initialAdmin);
        _grantRole(OPERATOR_ROLE, _initialAdmin);
        _grantRole(SIGNER_ROLE, _initialAdmin);

        // Grant withdrawal role to predetermined withdrawal address
        _grantRole(WITHDRAWAL_ROLE, _withdrawalAddress);
        // Set withdrawal role admin to withdrawal role to allow for delegation
        _setRoleAdmin(WITHDRAWAL_ROLE, WITHDRAWAL_ROLE);

        withdrawalAddress = _withdrawalAddress;
        launchId = _launchId;
        tokenDecimals = _tokenDecimals;
    }

    /// @notice Participate in a launch group
    /// @dev This allows users to participate in a launch group by submitting a participation request
    /// @dev This will transfer payment currency from user to contract and store participation info for user
    /// @param request Participation request
    /// @param signature Signature of the request
    function participate(ParticipationRequest calldata request, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
        onlyLaunchGroupStatus(request.launchGroupId, LaunchGroupStatus.ACTIVE)
    {
        // Validate request is intended for this launch and unexpired
        _validateRequest(
            request.launchId, request.launchGroupId, request.chainId, request.requestExpiresAt, request.userAddress
        );
        LaunchGroupSettings memory settings = launchGroupSettings[request.launchGroupId];

        // Validate launch group is open for participation
        _validateTimestamp(settings);

        // Validate request signature is from signer role
        _validateRequestSignature(keccak256(abi.encode(request)), signature);

        // Validate payment currency is enabled for launch group
        uint256 tokenPriceBps = _validateCurrency(request.launchGroupId, request.currency);

        // Do not allow replay of launch participation ID
        if (launchGroupParticipations[request.launchParticipationId].userId != bytes32(0)) {
            revert ParticipationAlreadyExists(request.launchParticipationId);
        }

        // If launch group does not finalize at participation, users should perform updates instead
        // This is checked by checking if the user has already requested tokens under the launch group
        EnumerableMap.Bytes32ToUintMap storage userTokens = _userTokensByLaunchGroup[request.launchGroupId];
        (, uint256 userTokenAmount) = userTokens.tryGet(request.userId);
        if (userTokenAmount > 0) {
            if (!settings.finalizesAtParticipation) {
                revert MaxUserParticipationsReached(request.launchGroupId, request.userId);
            }
        }

        // Validate user requested token amount is within launch group user allocation limits
        uint256 newUserTokenAmount = userTokenAmount + request.tokenAmount;
        if (newUserTokenAmount > settings.maxTokenAmountPerUser) {
            revert MaxUserTokenAllocationReached(
                request.launchGroupId, request.userId, userTokenAmount, request.tokenAmount
            );
        }
        if (newUserTokenAmount < settings.minTokenAmountPerUser) {
            revert MinUserTokenAllocationNotReached(
                request.launchGroupId, request.userId, userTokenAmount, request.tokenAmount
            );
        }

        // Calculate payment amount in requested currency based on token price and requested token amount
        uint256 currencyAmount = _calculateCurrencyAmount(tokenPriceBps, request.tokenAmount);

        // Store participation info for user
        ParticipationInfo storage info = launchGroupParticipations[request.launchParticipationId];

        // If launch group finalizes at participation, the participation is considered complete and not updatable
        if (settings.finalizesAtParticipation) {
            // Validate launch group max token allocation has not been reached
            (, uint256 currTotalTokensSold) = _tokensSoldByLaunchGroup.tryGet(request.launchGroupId);
            if (settings.maxTokenAllocation < currTotalTokensSold + request.tokenAmount) {
                revert MaxTokenAllocationReached(request.launchGroupId);
            }
            // Update total withdrawable amount for payment currency
            (, uint256 withdrawableAmount) = _withdrawableAmountByCurrency.tryGet(request.currency);
            _withdrawableAmountByCurrency.set(request.currency, withdrawableAmount + currencyAmount);
            // Mark participation as finalized
            info.isFinalized = true;
            // Update total tokens sold for launch group
            _tokensSoldByLaunchGroup.set(request.launchGroupId, currTotalTokensSold + request.tokenAmount);
        }
        // Set participation details for user
        info.userAddress = msg.sender;
        info.userId = request.userId;
        info.tokenAmount = request.tokenAmount;
        info.currencyAmount = currencyAmount;
        info.currency = request.currency;

        // Update total tokens requested for user for launch group
        userTokens.set(request.userId, newUserTokenAmount);
        // Transfer payment currency from user to contract
        IERC20(request.currency).safeTransferFrom(msg.sender, address(this), currencyAmount);

        emit ParticipationRegistered(
            request.launchGroupId,
            request.launchParticipationId,
            request.userId,
            msg.sender,
            currencyAmount,
            request.currency
        );
    }

    /// @notice Update requested token amount for existing participation
    /// @dev This allows users to update their requested token amount while committing funds or getting a refund
    /// @dev This is only allowed for launch groups that do not finalize at participation
    /// @param request Update participation request
    /// @param signature Signature of the request
    function updateParticipation(UpdateParticipationRequest calldata request, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
        onlyLaunchGroupStatus(request.launchGroupId, LaunchGroupStatus.ACTIVE)
    {
        // Validate request is intended for this launch and unexpired
        _validateRequest(
            request.launchId, request.launchGroupId, request.chainId, request.requestExpiresAt, request.userAddress
        );
        // Validate launch group is open for participation
        LaunchGroupSettings memory settings = launchGroupSettings[request.launchGroupId];
        _validateTimestamp(settings);
        // Validate request signature is from signer role
        _validateRequestSignature(keccak256(abi.encode(request)), signature);
        // Validate payment currency is enabled for launch group
        uint256 tokenPriceBps = _validateCurrency(request.launchGroupId, request.currency);

        ParticipationInfo storage prevInfo = launchGroupParticipations[request.prevLaunchParticipationId];
        // If launch group finalizes at participation, the participation is considered complete and not updatable
        if (settings.finalizesAtParticipation || prevInfo.isFinalized) {
            revert ParticipationUpdatesNotAllowed(request.launchGroupId, request.prevLaunchParticipationId);
        }

        // Validate participation exists and user, requested currency match
        ParticipationInfo storage newInfo = launchGroupParticipations[request.newLaunchParticipationId];
        if (request.currency != prevInfo.currency) {
            revert CurrencyMismatch(prevInfo.currency, request.currency);
        }
        if (request.userId != prevInfo.userId) {
            revert UserIdMismatch(prevInfo.userId, request.userId);
        }

        // Calculate new payment amount in requested currency based on token price and requested token amount
        uint256 newCurrencyAmount = _calculateCurrencyAmount(tokenPriceBps, request.tokenAmount);
        // Get total tokens requested for user for launch group
        EnumerableMap.Bytes32ToUintMap storage userTokens = _userTokensByLaunchGroup[request.launchGroupId];
        (, uint256 userTokenAmount) = userTokens.tryGet(request.userId);
        // If new requested token amount is less than old amount, handle refund
        if (prevInfo.currencyAmount > newCurrencyAmount) {
            // Calculate refund amount
            uint256 refundCurrencyAmount = prevInfo.currencyAmount - newCurrencyAmount;
            // Validate user new requested token amount is greater than min token amount per user
            if (userTokenAmount - refundCurrencyAmount < settings.minTokenAmountPerUser) {
                revert MinUserTokenAllocationNotReached(
                    request.launchGroupId, request.userId, userTokenAmount, request.tokenAmount
                );
            }
            // Update total tokens requested for user for launch group
            userTokens.set(request.userId, userTokenAmount - refundCurrencyAmount);
            // Transfer payment currency from contract to user
            IERC20(request.currency).safeTransfer(msg.sender, refundCurrencyAmount);
        } else if (newCurrencyAmount > prevInfo.currencyAmount) {
            // Calculate additional payment amount
            uint256 additionalCurrencyAmount = newCurrencyAmount - prevInfo.currencyAmount;
            // Validate user new requested token amount is within launch group user allocation limits
            if (userTokenAmount + additionalCurrencyAmount > settings.maxTokenAmountPerUser) {
                revert MaxUserTokenAllocationReached(
                    request.launchGroupId, request.userId, userTokenAmount, request.tokenAmount
                );
            }
            // Update total tokens requested for user for launch group
            userTokens.set(request.userId, userTokenAmount + additionalCurrencyAmount);
            // Transfer payment currency from user to contract
            IERC20(request.currency).safeTransferFrom(msg.sender, address(this), additionalCurrencyAmount);
        }

        // Set participation details for user
        newInfo.currencyAmount = newCurrencyAmount;
        newInfo.currency = request.currency;
        newInfo.userAddress = msg.sender;
        newInfo.userId = request.userId;
        newInfo.tokenAmount = request.tokenAmount;
        // Reset previous participation info
        prevInfo.currencyAmount = 0;
        prevInfo.tokenAmount = 0;

        emit ParticipationUpdated(
            request.launchGroupId,
            request.newLaunchParticipationId,
            request.userId,
            msg.sender,
            request.tokenAmount,
            request.currency
        );
    }

    /// @notice Cancel existing participation
    /// @dev This allows users to cancel their participation and get a refund
    /// @dev This is only allowed for launch groups that do not finalize at participation
    /// @param request Cancel participation request
    /// @param signature Signature of the request
    function cancelParticipation(CancelParticipationRequest calldata request, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
        onlyLaunchGroupStatus(request.launchGroupId, LaunchGroupStatus.ACTIVE)
    {
        // Validate request is intended for this launch and unexpired
        _validateRequest(
            request.launchId, request.launchGroupId, request.chainId, request.requestExpiresAt, request.userAddress
        );
        // Validate launch group is open for participation
        LaunchGroupSettings memory settings = launchGroupSettings[request.launchGroupId];
        _validateTimestamp(settings);
        // Validate request signature is from signer role
        _validateRequestSignature(keccak256(abi.encode(request)), signature);

        ParticipationInfo storage info = launchGroupParticipations[request.launchParticipationId];
        // If launch group finalizes at participation, the participation is considered complete and not updatable
        if (settings.finalizesAtParticipation) {
            revert ParticipationUpdatesNotAllowed(request.launchGroupId, request.launchParticipationId);
        }
        if (info.isFinalized) {
            revert ParticipationUpdatesNotAllowed(request.launchGroupId, request.launchParticipationId);
        }

        // Validate userId is the same which also checks if participation exists
        if (request.userId != info.userId) {
            revert UserIdMismatch(info.userId, request.userId);
        }

        // Get total tokens requested for user for launch group
        EnumerableMap.Bytes32ToUintMap storage userTokens = _userTokensByLaunchGroup[request.launchGroupId];
        (, uint256 userTokenAmount) = userTokens.tryGet(request.userId);
        if (userTokenAmount - info.tokenAmount == 0) {
            // If total tokens requested for user is the same as the cancelled participation, remove user from launch group
            userTokens.remove(request.userId);
        } else if (userTokenAmount - info.tokenAmount < settings.minTokenAmountPerUser) {
            // Total tokens requested for user after cancellation must be greater than min token amount per user
            revert MinUserTokenAllocationNotReached(
                request.launchGroupId, request.userId, userTokenAmount, info.tokenAmount
            );
        } else {
            // Subtract cancelled participation token amount from total tokens requested for user
            userTokens.set(request.userId, userTokenAmount - info.tokenAmount);
        }

        // Transfer payment currency from contract to user
        uint256 refundCurrencyAmount = info.currencyAmount;
        IERC20(info.currency).safeTransfer(info.userAddress, refundCurrencyAmount);

        // Reset participation info
        info.tokenAmount = 0;
        info.currencyAmount = 0;

        emit ParticipationCancelled(
            request.launchGroupId,
            request.launchParticipationId,
            request.userId,
            msg.sender,
            refundCurrencyAmount,
            info.currency
        );
    }

    /// @notice Claim refund for unfinalized participation
    /// @dev Users are only allowed to claim refund for completed launch groups if they did not participate successfully
    /// @dev This is only allowed for launch groups that do not finalize at participation
    /// @dev This can only happen after the launch group is marked as completed and the winners are finalized
    /// @param request Claim refund request
    /// @param signature Signature of the request
    function claimRefund(ClaimRefundRequest calldata request, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
        onlyLaunchGroupStatus(request.launchGroupId, LaunchGroupStatus.COMPLETED)
    {
        // Validate request is intended for this launch and unexpired
        _validateRequest(
            request.launchId, request.launchGroupId, request.chainId, request.requestExpiresAt, request.userAddress
        );
        // Validate request signature is from signer role
        _validateRequestSignature(keccak256(abi.encode(request)), signature);
        // Validate participation exists and user id matches
        ParticipationInfo storage info = launchGroupParticipations[request.launchParticipationId];
        if (request.userId != info.userId) {
            revert UserIdMismatch(info.userId, request.userId);
        }

        // Process refund
        _processRefund(request.launchGroupId, request.launchParticipationId, info);
    }

    /// @notice Batch process refunds for unfinalized participations
    /// @dev This allows operators to batch process refunds on behalf of users who did not participate successfully
    /// @dev This is only allowed for launch groups that do not finalize at participation
    /// @dev This can only happen after the launch group is marked as completed and the winners are finalized
    /// @param launchGroupId Launch group id
    /// @param launchParticipationIds Launch participation ids to process refunds for
    function batchRefund(bytes32 launchGroupId, bytes32[] calldata launchParticipationIds)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
        whenNotPaused
        onlyLaunchGroupStatus(launchGroupId, LaunchGroupStatus.COMPLETED)
    {
        for (uint256 i = 0; i < launchParticipationIds.length; i++) {
            ParticipationInfo storage info = launchGroupParticipations[launchParticipationIds[i]];
            _processRefund(launchGroupId, launchParticipationIds[i], info);
        }
    }

    /// @notice Finalize winners for a launch group
    /// @dev This should be done before launch group is marked as completed since users can
    /// @dev claim refunds after the launch group is marked as completed, however it does not
    /// @dev need to be done before the launch group settings close time
    /// @dev This is only allowed for launch groups that do not finalize at participation
    /// @param launchGroupId Launch group id
    /// @param winnerLaunchParticipationIds Launch participation ids to finalize as winners
    function finalizeWinners(bytes32 launchGroupId, bytes32[] calldata winnerLaunchParticipationIds)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
        onlyLaunchGroupStatus(launchGroupId, LaunchGroupStatus.ACTIVE)
    {
        // Validate launch group does not finalize at participation
        LaunchGroupSettings storage settings = launchGroupSettings[launchGroupId];
        if (settings.finalizesAtParticipation) {
            revert LaunchGroupFinalizesAtParticipation(launchGroupId);
        }

        // Get total tokens sold (finalized participations) so far for launch group
        (, uint256 totalTokensSold) = _tokensSoldByLaunchGroup.tryGet(launchGroupId);
        uint256 currTotalTokensSold = totalTokensSold;
        for (uint256 i = 0; i < winnerLaunchParticipationIds.length; i++) {
            // Get participation info for the winning participation id
            ParticipationInfo storage info = launchGroupParticipations[winnerLaunchParticipationIds[i]];

            // If participation is finalized or has no token amount or no currency amount (cancelled), revert
            if (info.isFinalized || info.tokenAmount == 0 || info.currencyAmount == 0) {
                revert InvalidWinner(winnerLaunchParticipationIds[i], info.userId);
            }
            // Validate max token allocation has not been reached for launch group
            if (settings.maxTokenAllocation < currTotalTokensSold + info.tokenAmount) {
                revert MaxTokenAllocationReached(launchGroupId);
            }

            // Update total withdrawable amount for payment currency
            (, uint256 withdrawableAmount) = _withdrawableAmountByCurrency.tryGet(info.currency);
            _withdrawableAmountByCurrency.set(info.currency, withdrawableAmount + info.currencyAmount);

            // Mark participation as finalized
            info.isFinalized = true;

            // Update total tokens sold for launch group
            currTotalTokensSold += info.tokenAmount;

            emit WinnerSelected(launchGroupId, winnerLaunchParticipationIds[i], info.userId, info.userAddress);
        }
        _tokensSoldByLaunchGroup.set(launchGroupId, currTotalTokensSold);
    }

    /// @notice Withdraw funds for currency
    /// @dev All launch groups must be marked as completed before any funds can be withdrawn
    /// @dev This should only contain funds from finalized participations
    /// @param currency Currency to withdraw
    /// @param amount Amount to withdraw
    function withdraw(address currency, uint256 amount) external nonReentrant whenNotPaused onlyRole(WITHDRAWAL_ROLE) {
        // Validate all launch groups are completed
        bytes32[] memory launchGroupIds = _launchGroups.values();
        for (uint256 i = 0; i < launchGroupIds.length; i++) {
            if (launchGroupSettings[launchGroupIds[i]].status != LaunchGroupStatus.COMPLETED) {
                revert InvalidLaunchGroupStatus(
                    launchGroupIds[i], LaunchGroupStatus.COMPLETED, launchGroupSettings[launchGroupIds[i]].status
                );
            }
        }
        // Validate withdrawable amount is greater than or equal to requested amount to withdraw
        (, uint256 withdrawableAmount) = _withdrawableAmountByCurrency.tryGet(currency);
        if (withdrawableAmount < amount) {
            revert InvalidWithdrawalAmount(amount, withdrawableAmount);
        }

        // Update withdrawable amount for payment currency
        _withdrawableAmountByCurrency.set(currency, withdrawableAmount - amount);

        // Transfer payment currency from contract to withdrawal address
        IERC20(currency).safeTransfer(withdrawalAddress, amount);

        emit Withdrawal(withdrawalAddress, currency, amount);
    }

    /// @notice Calculate currency payment amount based on bps and token amount
    function _calculateCurrencyAmount(uint256 tokenPriceBps, uint256 tokenAmount) internal view returns (uint256) {
        return Math.mulDiv(tokenPriceBps, tokenAmount, 10 ** tokenDecimals);
    }

    /// @notice Validate request signature is signed by a signer role
    function _validateRequestSignature(bytes32 messageHash, bytes calldata signature) private view {
        address signer = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(messageHash), signature);
        if (!hasRole(SIGNER_ROLE, signer)) {
            revert InvalidSignature();
        }
    }

    /// @notice Process refund for a participation
    function _processRefund(bytes32 launchGroupId, bytes32 launchParticipationId, ParticipationInfo storage info)
        private
    {
        // If participation is finalized or has no currency amount or no token amount (cancelled), revert
        if (info.isFinalized || info.currencyAmount == 0 || info.tokenAmount == 0) {
            revert InvalidRefundRequest(launchParticipationId, info.userId);
        }

        // Subtract refunded participation token amount from total tokens requested for user
        EnumerableMap.Bytes32ToUintMap storage userTokens = _userTokensByLaunchGroup[launchGroupId];
        (, uint256 userTokenAmount) = userTokens.tryGet(info.userId);
        userTokens.set(info.userId, userTokenAmount - info.tokenAmount);

        // Reset participation info
        uint256 refundCurrencyAmount = info.currencyAmount;
        info.tokenAmount = 0;
        info.currencyAmount = 0;

        // Transfer payment currency from contract to user
        IERC20(info.currency).safeTransfer(info.userAddress, refundCurrencyAmount);

        emit RefundClaimed(
            launchGroupId, launchParticipationId, info.userId, info.userAddress, refundCurrencyAmount, info.currency
        );
    }

    /// @notice Validates common request parameters
    function _validateRequest(
        bytes32 _launchId,
        bytes32 _launchGroupId,
        uint256 _chainId,
        uint256 _requestExpiresAt,
        address _userAddress
    ) private view {
        // Validate launch id, chain id, user address, and launch group is valid
        if (
            _launchId != launchId || _chainId != block.chainid || msg.sender != _userAddress
                || !_launchGroups.contains(_launchGroupId)
        ) {
            revert InvalidRequest();
        }

        // Validate request has not expired
        if (_requestExpiresAt <= block.timestamp) {
            revert ExpiredRequest(_requestExpiresAt, block.timestamp);
        }
    }

    /// @notice Validates launch group is open for participation
    function _validateTimestamp(LaunchGroupSettings memory settings) private view {
        if (block.timestamp < settings.startsAt || block.timestamp > settings.endsAt) {
            revert InvalidRequest();
        }
    }

    /// @notice Validate payment currency is enabled for a launch group
    /// @dev This returns the token price bps for the currency to reduce reads to calculate required currency amount
    function _validateCurrency(bytes32 _launchGroupId, address _currency) private view returns (uint256) {
        CurrencyConfig memory currencyConfig = _launchGroupCurrencies[_launchGroupId][_currency];
        if (!currencyConfig.isEnabled) {
            revert InvalidRequest();
        }
        return currencyConfig.tokenPriceBps;
    }

    /// @notice Validate currency config
    function _validateCurrencyConfig(CurrencyConfig calldata currencyConfig) private pure {
        if (currencyConfig.tokenPriceBps == 0) {
            revert InvalidRequest();
        }
    }

    /// @notice Validate launch group status transition
    /// @dev Status changes to pending are not allowed since other statuses can involve state changes
    /// @dev Status changes from completed are not allowed since it is the terminal state
    /// @dev and users can start claiming refunds after the launch group is marked as completed
    function _validateStatusTransition(LaunchGroupStatus prevStatus, LaunchGroupStatus newStatus) private pure {
        if (prevStatus != newStatus) {
            if (newStatus == LaunchGroupStatus.PENDING || prevStatus == LaunchGroupStatus.COMPLETED) {
                revert InvalidRequest();
            }
        }
    }

    /// @notice Create a new launch group
    /// @param launchGroupId Launch group id from Rova
    /// @param initialCurrency Initial payment currency (ERC20) to configure for launch group
    /// @param initialCurrencyConfig Initial payment currency config to configure for launch group
    /// @param settings Launch group settings
    function createLaunchGroup(
        bytes32 launchGroupId,
        address initialCurrency,
        CurrencyConfig calldata initialCurrencyConfig,
        LaunchGroupSettings calldata settings
    ) external onlyRole(MANAGER_ROLE) {
        // Validate launch group id is not already created
        if (_launchGroups.contains(launchGroupId)) {
            revert InvalidRequest();
        }
        // Validate initial currency config
        _validateCurrencyConfig(initialCurrencyConfig);

        // Set launch group settings
        launchGroupSettings[launchGroupId] = settings;
        // Set initial currency config for launch group
        _launchGroupCurrencies[launchGroupId][initialCurrency] = initialCurrencyConfig;
        // Add launch group id to launch groups
        _launchGroups.add(launchGroupId);

        emit LaunchGroupCreated(launchGroupId);
    }

    /// @notice Set launch group currency config
    /// @dev This allows managers to add new payment currencies to a launch group
    /// @param launchGroupId Launch group id from Rova
    /// @param currency Address of the currency (ERC20) to set config for
    /// @param currencyConfig Currency config to set for launch group
    function setLaunchGroupCurrency(bytes32 launchGroupId, address currency, CurrencyConfig calldata currencyConfig)
        external
        onlyRole(MANAGER_ROLE)
    {
        // Validate currency config
        _validateCurrencyConfig(currencyConfig);
        // Set currency config for launch group
        _launchGroupCurrencies[launchGroupId][currency] = currencyConfig;

        emit LaunchGroupCurrencyUpdated(launchGroupId, currency);
    }

    /// @notice Enable or disable a launch group currency
    /// @dev This allows managers to enable or disable payment currencies for a launch group
    function toggleLaunchGroupCurrencyEnabled(bytes32 launchGroupId, address currency, bool isEnabled)
        external
        onlyRole(MANAGER_ROLE)
    {
        _launchGroupCurrencies[launchGroupId][currency].isEnabled = isEnabled;
        emit LaunchGroupCurrencyUpdated(launchGroupId, currency);
    }

    /// @notice Set launch group settings
    /// @dev The finalizesAtParticipation setting can only be updated before the launch group is active
    function setLaunchGroupSettings(bytes32 launchGroupId, LaunchGroupSettings calldata settings)
        external
        onlyRole(MANAGER_ROLE)
    {
        // Validate launch group exists
        if (!_launchGroups.contains(launchGroupId)) {
            revert InvalidRequest();
        }
        // Validate status transition
        LaunchGroupSettings memory prevSettings = launchGroupSettings[launchGroupId];
        _validateStatusTransition(prevSettings.status, settings.status);
        // The finalizesAtParticipation setting can only be updated while the launch group is pending
        if (
            prevSettings.status != LaunchGroupStatus.PENDING
                && settings.finalizesAtParticipation != prevSettings.finalizesAtParticipation
        ) {
            revert InvalidRequest();
        }
        // Set launch group settings
        launchGroupSettings[launchGroupId] = settings;

        emit LaunchGroupUpdated(launchGroupId);
    }

    /// @notice Set launch identifier
    /// @dev This will typically not be used unless there is a mistake during launch creation
    function setLaunchId(bytes32 _launchId) external onlyRole(MANAGER_ROLE) {
        launchId = _launchId;
    }

    /// @notice Set launch group status
    /// @dev This allows managers to update the status of a launch group
    function setLaunchGroupStatus(bytes32 launchGroupId, LaunchGroupStatus status) external onlyRole(MANAGER_ROLE) {
        // Validate status transition
        _validateStatusTransition(launchGroupSettings[launchGroupId].status, status);
        // Set launch group status
        launchGroupSettings[launchGroupId].status = status;
        emit LaunchGroupStatusUpdated(launchGroupId, status);
    }

    /// @notice Set withdrawal address
    /// @dev This allows the withdrawal role to update the launch withdrawal address
    function setWithdrawalAddress(address _withdrawalAddress) external onlyRole(WITHDRAWAL_ROLE) {
        if (_withdrawalAddress == address(0)) {
            revert InvalidRequest();
        }
        withdrawalAddress = _withdrawalAddress;
        emit WithdrawalAddressUpdated(_withdrawalAddress);
    }

    /// @notice Get all launch group ids
    function getLaunchGroups() external view returns (bytes32[] memory) {
        return _launchGroups.values();
    }

    /// @notice Get launch group status for a launch group
    function getLaunchGroupStatus(bytes32 launchGroupId) external view returns (LaunchGroupStatus) {
        return launchGroupSettings[launchGroupId].status;
    }

    /// @notice Get launch group settings for a launch group
    function getLaunchGroupSettings(bytes32 launchGroupId) external view returns (LaunchGroupSettings memory) {
        return launchGroupSettings[launchGroupId];
    }

    /// @notice Get currency config for a launch group and currency
    function getLaunchGroupCurrencyConfig(bytes32 launchGroupId, address currency)
        external
        view
        returns (CurrencyConfig memory)
    {
        return _launchGroupCurrencies[launchGroupId][currency];
    }

    /// @notice Get participation info for a launch participation
    function getParticipationInfo(bytes32 launchParticipationId) external view returns (ParticipationInfo memory) {
        return launchGroupParticipations[launchParticipationId];
    }

    /// @notice Get all user ids for a launch group
    /// @dev This should not be called by other state-changing functions to avoid gas issues
    function getLaunchGroupParticipantUserIds(bytes32 launchGroupId) external view returns (bytes32[] memory) {
        return _userTokensByLaunchGroup[launchGroupId].keys();
    }

    /// @notice Get total number of unique participants for a launch group
    /// @dev This is based on user identifier rather than user address since users can use multiple addresses to fund
    function getNumUniqueParticipantsByLaunchGroup(bytes32 launchGroupId) external view returns (uint256) {
        return _userTokensByLaunchGroup[launchGroupId].length();
    }

    /// @notice Get withdrawable amount for a currency
    function getWithdrawableAmountByCurrency(address currency) external view returns (uint256) {
        (, uint256 amount) = _withdrawableAmountByCurrency.tryGet(currency);
        return amount;
    }

    /// @notice Get total tokens sold for a launch group
    function getTokensSoldByLaunchGroup(bytes32 launchGroupId) external view returns (uint256) {
        (, uint256 tokensSold) = _tokensSoldByLaunchGroup.tryGet(launchGroupId);
        return tokensSold;
    }

    /// @notice Get total tokens sold for a user in a launch group
    function getUserTokensByLaunchGroup(bytes32 launchGroupId, bytes32 userId) external view returns (uint256) {
        (, uint256 tokensSold) = _userTokensByLaunchGroup[launchGroupId].tryGet(userId);
        return tokensSold;
    }

    /// @notice Pause the contract
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Modifier to check launch group status
    modifier onlyLaunchGroupStatus(bytes32 launchGroupId, LaunchGroupStatus status) {
        if (launchGroupSettings[launchGroupId].status != status) {
            revert InvalidLaunchGroupStatus(launchGroupId, status, launchGroupSettings[launchGroupId].status);
        }
        _;
    }
}
