// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.22;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Test} from "forge-std/Test.sol";
import {LaunchTestBase} from "./LaunchTestBase.t.sol";
import {Launch} from "../src/Launch.sol";
import {
    LaunchGroupSettings,
    LaunchGroupStatus,
    ParticipationRequest,
    UpdateParticipationRequest,
    ParticipationInfo,
    CurrencyConfig
} from "../src/Types.sol";

contract LaunchUpdateParticipationTest is Test, Launch, LaunchTestBase {
    LaunchGroupSettings public settings;
    ParticipationRequest public originalParticipationRequest;

    function setUp() public {
        _setUpLaunch();

        // Setup initial participation
        settings = _setupLaunchGroup();
        originalParticipationRequest = _createParticipationRequest();
        bytes memory signature = _signRequest(abi.encode(originalParticipationRequest));

        vm.startPrank(user1);
        currency.approve(
            address(launch),
            _getCurrencyAmount(
                originalParticipationRequest.launchGroupId,
                originalParticipationRequest.currency,
                originalParticipationRequest.tokenAmount
            )
        );
        launch.participate(originalParticipationRequest, signature);

        vm.stopPrank();
    }

    function test_UpdateParticipation_IncreaseAmount() public {
        // Prepare update participation request
        UpdateParticipationRequest memory updateRequest = _createUpdateParticipationRequest(2000);
        bytes memory updateSignature = _signRequest(abi.encode(updateRequest));

        vm.startPrank(user1);
        uint256 updatedCurrencyAmount =
            _getCurrencyAmount(updateRequest.launchGroupId, updateRequest.currency, updateRequest.tokenAmount);
        currency.approve(address(launch), updatedCurrencyAmount);

        // Expect ParticipationUpdated event
        vm.expectEmit();
        emit ParticipationUpdated(
            updateRequest.launchGroupId,
            updateRequest.newLaunchParticipationId,
            testUserId,
            user1,
            updateRequest.tokenAmount,
            address(currency)
        );

        // Update participation
        launch.updateParticipation(updateRequest, updateSignature);

        // Verify update
        ParticipationInfo memory newInfo = launch.getParticipationInfo(updateRequest.newLaunchParticipationId);
        _verifyParticipationInfo(newInfo, updateRequest);
        ParticipationInfo memory oldInfo = launch.getParticipationInfo(updateRequest.prevLaunchParticipationId);
        assertEq(oldInfo.currencyAmount, 0);
        assertEq(oldInfo.tokenAmount, 0);

        // Verify total unique participants by launch group
        assertEq(launch.getNumUniqueParticipantsByLaunchGroup(testLaunchGroupId), 1);

        vm.stopPrank();
    }

    function test_UpdateParticipation_DecreaseAmount() public {
        // Prepare update participation request
        UpdateParticipationRequest memory updateRequest = _createUpdateParticipationRequest(500);

        bytes memory updateSignature = _signRequest(abi.encode(updateRequest));
        uint256 initialCurrencyBalance = currency.balanceOf(user1);

        // Expect ParticipationUpdated event
        vm.expectEmit();
        emit ParticipationUpdated(
            updateRequest.launchGroupId,
            updateRequest.newLaunchParticipationId,
            testUserId,
            user1,
            updateRequest.tokenAmount,
            address(currency)
        );

        vm.startPrank(user1);
        // Update participation
        launch.updateParticipation(updateRequest, updateSignature);

        // Verify update
        ParticipationInfo memory newInfo = launch.getParticipationInfo(updateRequest.newLaunchParticipationId);
        _verifyParticipationInfo(newInfo, updateRequest);
        ParticipationInfo memory oldInfo = launch.getParticipationInfo(updateRequest.prevLaunchParticipationId);
        assertEq(oldInfo.currencyAmount, 0);
        assertEq(oldInfo.tokenAmount, 0);

        // Verify refund
        assertEq(currency.balanceOf(user1), initialCurrencyBalance + 500 * 10 ** launch.tokenDecimals());

        // Verify total unique participants by launch group
        assertEq(launch.getNumUniqueParticipantsByLaunchGroup(testLaunchGroupId), 1);

        vm.stopPrank();
    }

    function test_RevertIf_UpdateParticipation_LaunchPaused() public {
        vm.startPrank(admin.addr);
        launch.pause();
        vm.stopPrank();

        // Prepare update participation request
        UpdateParticipationRequest memory request = _createUpdateParticipationRequest(1000);
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        // Update participation
        launch.updateParticipation(request, signature);
    }

    function test_RevertIf_UpdateParticipation_InvalidLaunchGroupStatus() public {
        // Update launch group status
        vm.startPrank(manager);
        launch.setLaunchGroupStatus(testLaunchGroupId, LaunchGroupStatus.PAUSED);
        vm.stopPrank();

        // Prepare update participation request
        UpdateParticipationRequest memory request = _createUpdateParticipationRequest(1000);
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidLaunchGroupStatus.selector, testLaunchGroupId, LaunchGroupStatus.ACTIVE, LaunchGroupStatus.PAUSED
            )
        );
        // Update participation
        launch.updateParticipation(request, signature);
    }

    function test_RevertIf_UpdateParticipation_InvalidRequestLaunchId() public {
        // Prepare update participation request
        UpdateParticipationRequest memory request = _createUpdateParticipationRequest(1000);
        request.launchId = "invalidLaunchId";
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(InvalidRequest.selector);
        // Update participation
        launch.updateParticipation(request, signature);
    }

    function test_RevertIf_UpdateParticipation_InvalidRequestChainId() public {
        // Prepare update participation request
        UpdateParticipationRequest memory request = _createUpdateParticipationRequest(1000);
        request.chainId = 1;
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(InvalidRequest.selector);
        // Update participation
        launch.updateParticipation(request, signature);
    }

    function test_RevertIf_UpdateParticipation_InvalidRequestStartsAtTimestamp() public {
        // Prepare update participation request
        UpdateParticipationRequest memory request = _createUpdateParticipationRequest(1000);
        vm.warp(settings.startsAt - 1);
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(InvalidRequest.selector);
        // Update participation
        launch.updateParticipation(request, signature);
    }

    function test_RevertIf_UpdateParticipation_InvalidRequestEndsAtTimestamp() public {
        // Prepare update participation request
        UpdateParticipationRequest memory request = _createUpdateParticipationRequest(1000);
        vm.warp(settings.endsAt + 1 hours);
        request.requestExpiresAt = settings.endsAt + 2 hours;
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(InvalidRequest.selector);
        // Update participation
        launch.updateParticipation(request, signature);
    }

    function test_RevertIf_UpdateParticipation_InvalidRequestUserAddress() public {
        // Prepare update participation request
        UpdateParticipationRequest memory request = _createUpdateParticipationRequest(1000);
        request.userAddress = address(0);
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(InvalidRequest.selector);
        // Update participation
        launch.updateParticipation(request, signature);
    }

    function test_RevertIf_UpdateParticipation_ExpiredRequest() public {
        // Prepare update participation request
        UpdateParticipationRequest memory request = _createUpdateParticipationRequest(1000);
        request.requestExpiresAt = 0;
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExpiredRequest.selector, request.requestExpiresAt, block.timestamp));
        // Update participation
        launch.updateParticipation(request, signature);
    }

    function test_RevertIf_UpdateParticipation_InvalidSignatureSigner() public {
        // Prepare update participation request
        UpdateParticipationRequest memory request = _createUpdateParticipationRequest(1000);
        bytes memory signature = _signRequestWithSigner(abi.encode(request), 0x1234567890);

        vm.startPrank(user1);
        vm.expectRevert(InvalidSignature.selector);
        // Update participation
        launch.updateParticipation(request, signature);
    }

    function test_RevertIf_UpdateParticipation_InvalidSignatureInput() public {
        // Prepare update participation request
        UpdateParticipationRequest memory request = _createUpdateParticipationRequest(1000);
        bytes memory signature = _signRequest(abi.encode(_createUpdateParticipationRequest(2000)));

        vm.startPrank(user1);
        vm.expectRevert(InvalidSignature.selector);
        // Update participation
        launch.updateParticipation(request, signature);
    }

    function test_RevertIf_UpdateParticipation_ParticipationUpdatesNotAllowedIfFinalizesAtParticipation() public {
        // Create new launch group to be able to edit finalizesAtParticipation
        bytes32 launchGroupId = bytes32(uint256(1));
        LaunchGroupSettings memory customSettings =
            _setupLaunchGroupWithStatus(launchGroupId, LaunchGroupStatus.PENDING);
        customSettings.finalizesAtParticipation = true;
        customSettings.status = LaunchGroupStatus.ACTIVE;

        // Update launch group settings
        vm.startPrank(manager);
        launch.setLaunchGroupSettings(launchGroupId, customSettings);
        vm.stopPrank();

        // Participate
        bytes32 newLaunchParticipationId = "newLaunchParticipationId";
        ParticipationRequest memory participationRequest = _createParticipationRequest();
        participationRequest.launchGroupId = launchGroupId;
        participationRequest.launchParticipationId = newLaunchParticipationId;
        bytes memory participationSignature = _signRequest(abi.encode(participationRequest));
        vm.startPrank(user1);
        currency.approve(
            address(launch),
            _getCurrencyAmount(
                participationRequest.launchGroupId, participationRequest.currency, participationRequest.tokenAmount
            )
        );
        launch.participate(participationRequest, participationSignature);
        vm.stopPrank();

        // Prepare update participation request
        UpdateParticipationRequest memory updateRequest = _createUpdateParticipationRequest(1000);
        updateRequest.launchGroupId = launchGroupId;
        updateRequest.newLaunchParticipationId = newLaunchParticipationId;
        bytes memory updateSignature = _signRequest(abi.encode(updateRequest));

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(ParticipationUpdatesNotAllowed.selector, launchGroupId, testLaunchParticipationId)
        );
        // Update participation
        launch.updateParticipation(updateRequest, updateSignature);
    }

    function test_RevertIf_UpdateParticipation_InvalidRequestCurrencyNotRegistered() public {
        // Prepare update participation request
        UpdateParticipationRequest memory request = _createUpdateParticipationRequest(1000);
        request.currency = address(20);
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(InvalidRequest.selector);
        // Update participation
        launch.updateParticipation(request, signature);
    }

    function test_RevertIf_UpdateParticipation_InvalidRequestCurrencyNotEnabled() public {
        // Register new currency
        vm.startPrank(manager);
        launch.setLaunchGroupCurrency(
            testLaunchGroupId, address(20), CurrencyConfig({tokenPriceBps: 10000, isEnabled: false})
        );
        vm.stopPrank();

        // Prepare update participation request
        UpdateParticipationRequest memory request = _createUpdateParticipationRequest(1000);
        request.currency = address(20);
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(InvalidRequest.selector);
        // Update participation
        launch.updateParticipation(request, signature);
    }

    function test_RevertIf_UpdateParticipation_CurrencyMismatch() public {
        // Register new currency
        vm.startPrank(manager);
        launch.setLaunchGroupCurrency(
            testLaunchGroupId, address(20), CurrencyConfig({tokenPriceBps: 10000, isEnabled: true})
        );
        vm.stopPrank();

        // Prepare update participation request
        UpdateParticipationRequest memory request = _createUpdateParticipationRequest(1000);
        request.currency = address(20);
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(CurrencyMismatch.selector, address(currency), address(request.currency)));
        // Update participation
        launch.updateParticipation(request, signature);
    }

    function test_RevertIf_UpdateParticipation_UserIdMismatch() public {
        // Prepare update participation request
        UpdateParticipationRequest memory request = _createUpdateParticipationRequest(1000);
        request.userId = "invalidUserId";
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(UserIdMismatch.selector, testUserId, request.userId));
        // Update participation
        launch.updateParticipation(request, signature);
    }

    function test_RevertIf_UpdateParticipation_MinUserTokenAllocationReached() public {
        // Setup launch group
        uint256 normalizedTokenAmount = 1000;
        vm.startPrank(manager);
        settings.minTokenAmountPerUser = normalizedTokenAmount * 10 ** launch.tokenDecimals();
        launch.setLaunchGroupSettings(testLaunchGroupId, settings);
        vm.stopPrank();

        // Prepare update participation request
        UpdateParticipationRequest memory request = _createUpdateParticipationRequest(normalizedTokenAmount - 1);
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                MinUserTokenAllocationNotReached.selector,
                testLaunchGroupId,
                testUserId,
                originalParticipationRequest.tokenAmount,
                request.tokenAmount
            )
        );
        // Update participation
        launch.updateParticipation(request, signature);
    }

    function test_RevertIf_UpdateParticipation_MaxUserTokenAllocationReached() public {
        // Setup launch group
        uint256 normalizedTokenAmount = 1000;
        vm.startPrank(manager);
        settings.maxTokenAmountPerUser = normalizedTokenAmount * 10 ** launch.tokenDecimals();
        launch.setLaunchGroupSettings(testLaunchGroupId, settings);
        vm.stopPrank();

        // Prepare update participation request
        UpdateParticipationRequest memory request = _createUpdateParticipationRequest(normalizedTokenAmount + 1);
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                MaxUserTokenAllocationReached.selector,
                testLaunchGroupId,
                testUserId,
                originalParticipationRequest.tokenAmount,
                request.tokenAmount
            )
        );
        // Update participation
        launch.updateParticipation(request, signature);
    }

    function test_RevertIf_UpdateParticipation_ERC20InsufficientBalance() public {
        // Prepare update participation request
        ParticipationInfo memory initialInfo = launch.getParticipationInfo(testLaunchParticipationId);
        UpdateParticipationRequest memory request = _createUpdateParticipationRequest(2000);
        bytes memory signature = _signRequest(abi.encode(request));
        uint256 additionalCurrencyAmount = _getCurrencyAmount(
            request.launchGroupId, request.currency, request.tokenAmount
        ) - initialInfo.currencyAmount;

        vm.startPrank(user1);
        currency.transfer(user2, currency.balanceOf(user1));
        currency.approve(address(launch), additionalCurrencyAmount);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 0, additionalCurrencyAmount)
        );
        // Update participation
        launch.updateParticipation(request, signature);
    }

    function _verifyParticipationInfo(ParticipationInfo memory info, UpdateParticipationRequest memory updateRequest)
        internal
        view
    {
        assertEq(info.userAddress, user1);
        assertEq(info.userId, testUserId);
        assertEq(info.tokenAmount, updateRequest.tokenAmount);
        assertEq(
            info.currencyAmount,
            _getCurrencyAmount(updateRequest.launchGroupId, updateRequest.currency, updateRequest.tokenAmount)
        );
        assertEq(info.currency, address(currency));
        assertEq(info.isFinalized, false);
    }

    function _createUpdateParticipationRequest(uint256 newTokenAmount)
        internal
        view
        returns (UpdateParticipationRequest memory)
    {
        uint256 launchTokenDecimals = launch.tokenDecimals();
        return UpdateParticipationRequest({
            chainId: block.chainid,
            launchId: testLaunchId,
            launchGroupId: testLaunchGroupId,
            prevLaunchParticipationId: testLaunchParticipationId,
            newLaunchParticipationId: "newLaunchParticipationId",
            userId: testUserId,
            userAddress: user1,
            tokenAmount: newTokenAmount * 10 ** launchTokenDecimals,
            currency: address(currency),
            requestExpiresAt: block.timestamp + 1 hours
        });
    }
}
