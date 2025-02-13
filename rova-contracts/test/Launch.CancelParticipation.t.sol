// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.22;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Test} from "forge-std/Test.sol";
import {LaunchTestBase} from "./LaunchTestBase.t.sol";
import {Launch} from "../src/Launch.sol";
import {
    LaunchGroupSettings,
    LaunchGroupStatus,
    ParticipationRequest,
    ParticipationInfo,
    CancelParticipationRequest
} from "../src/Types.sol";

contract LaunchCancelParticipationTest is Test, Launch, LaunchTestBase {
    LaunchGroupSettings public settings;

    function setUp() public {
        _setUpLaunch();

        // Setup initial participation
        settings = _setupLaunchGroup();
        ParticipationRequest memory request = _createParticipationRequest();
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        currency.approve(
            address(launch), _getCurrencyAmount(request.launchGroupId, request.currency, request.tokenAmount)
        );
        launch.participate(request, signature);

        vm.stopPrank();
    }

    function test_CancelParticipation() public {
        // Prepare cancel participation request
        CancelParticipationRequest memory cancelRequest = _createCancelParticipationRequest();
        bytes memory cancelSignature = _signRequest(abi.encode(cancelRequest));

        ParticipationInfo memory info = launch.getParticipationInfo(cancelRequest.launchParticipationId);
        assertEq(info.tokenAmount, 1000 * 10 ** 18);
        assertEq(info.currencyAmount, 1000 * 10 ** 18);
        uint256 initialUserTokenAmount = launch.getUserTokensByLaunchGroup(testLaunchGroupId, testUserId);
        uint256 startingBalance = currency.balanceOf(user1);

        vm.startPrank(user1);

        // Expect ParticipationCancelled event
        vm.expectEmit();
        emit ParticipationCancelled(
            cancelRequest.launchGroupId,
            cancelRequest.launchParticipationId,
            cancelRequest.userId,
            user1,
            info.currencyAmount,
            address(currency)
        );

        // Update participation
        launch.cancelParticipation(cancelRequest, cancelSignature);
        vm.stopPrank();

        // Verify update
        ParticipationInfo memory newInfo = launch.getParticipationInfo(cancelRequest.launchParticipationId);
        assertEq(newInfo.tokenAmount, 0);
        assertEq(newInfo.currencyAmount, 0);

        // Verify user balance
        assertEq(currency.balanceOf(user1), startingBalance + info.currencyAmount);

        // Verify user tokens
        uint256 userTokenAmount = launch.getUserTokensByLaunchGroup(testLaunchGroupId, testUserId);
        assertEq(userTokenAmount, initialUserTokenAmount - info.tokenAmount);

        // Verify user ID is no longer in the launch group
        assertEq(launch.getLaunchGroupParticipantUserIds(testLaunchGroupId).length, 0);
    }

    function test_RevertIf_CancelParticipation_LaunchPaused() public {
        vm.startPrank(admin.addr);
        launch.pause();
        vm.stopPrank();

        // Prepare cancel participation request
        CancelParticipationRequest memory request = _createCancelParticipationRequest();
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        // Cancel participation
        launch.cancelParticipation(request, signature);
    }

    function test_RevertIf_CancelParticipation_InvalidLaunchGroupStatus() public {
        // Update launch group status
        vm.startPrank(manager);
        launch.setLaunchGroupStatus(testLaunchGroupId, LaunchGroupStatus.PAUSED);
        vm.stopPrank();

        // Prepare cancel participation request
        CancelParticipationRequest memory request = _createCancelParticipationRequest();
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidLaunchGroupStatus.selector, testLaunchGroupId, LaunchGroupStatus.ACTIVE, LaunchGroupStatus.PAUSED
            )
        );
        // Cancel participation
        launch.cancelParticipation(request, signature);
    }

    function test_RevertIf_CancelParticipation_InvalidRequestLaunchId() public {
        // Prepare cancel participation request
        CancelParticipationRequest memory request = _createCancelParticipationRequest();
        request.launchId = "invalidLaunchId";
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(InvalidRequest.selector);
        // Cancel participation
        launch.cancelParticipation(request, signature);
    }

    function test_RevertIf_CancelParticipation_InvalidRequestChainId() public {
        // Prepare cancel participation request
        CancelParticipationRequest memory request = _createCancelParticipationRequest();
        request.chainId = 1;
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(InvalidRequest.selector);
        // Cancel participation
        launch.cancelParticipation(request, signature);
    }

    function test_RevertIf_CancelParticipation_InvalidRequestStartsAtTimestamp() public {
        // Prepare cancel participation request
        CancelParticipationRequest memory request = _createCancelParticipationRequest();
        vm.warp(settings.startsAt - 1);
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(InvalidRequest.selector);
        // Cancel participation
        launch.cancelParticipation(request, signature);
    }

    function test_RevertIf_CancelParticipation_InvalidRequestEndsAtTimestamp() public {
        // Prepare cancel participation request
        CancelParticipationRequest memory request = _createCancelParticipationRequest();
        vm.warp(settings.endsAt + 1 hours);
        request.requestExpiresAt = settings.endsAt + 2 hours;
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(InvalidRequest.selector);
        // Cancel participation
        launch.cancelParticipation(request, signature);
    }

    function test_RevertIf_CancelParticipation_InvalidRequestUserAddress() public {
        // Prepare cancel participation request
        CancelParticipationRequest memory request = _createCancelParticipationRequest();
        request.userAddress = address(0);
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(InvalidRequest.selector);
        // Cancel participation
        launch.cancelParticipation(request, signature);
    }

    function test_RevertIf_CancelParticipation_ExpiredRequest() public {
        // Prepare cancel participation request
        CancelParticipationRequest memory request = _createCancelParticipationRequest();
        request.requestExpiresAt = 0;
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(ExpiredRequest.selector, request.requestExpiresAt, block.timestamp));
        // Cancel participation
        launch.cancelParticipation(request, signature);
    }

    function test_RevertIf_CancelParticipation_InvalidSignatureSigner() public {
        // Prepare cancel participation request
        CancelParticipationRequest memory request = _createCancelParticipationRequest();
        bytes memory signature = _signRequestWithSigner(abi.encode(request), 0x1234567890);

        vm.startPrank(user1);
        vm.expectRevert(InvalidSignature.selector);
        // Cancel participation
        launch.cancelParticipation(request, signature);
    }

    function test_RevertIf_CancelParticipation_InvalidSignatureInput() public {
        // Prepare cancel participation request
        CancelParticipationRequest memory request = _createCancelParticipationRequest();
        request.requestExpiresAt = block.timestamp + 4 hours;
        bytes memory signature = _signRequest(abi.encode(_createCancelParticipationRequest()));

        vm.startPrank(user1);
        vm.expectRevert(InvalidSignature.selector);
        // Cancel participation
        launch.cancelParticipation(request, signature);
    }

    function test_RevertIf_CancelParticipation_ParticipationUpdatesNotAllowedIfFinalizesAtParticipation() public {
        // Setup new launch group
        bytes32 launchGroupId = bytes32(uint256(1));
        LaunchGroupSettings memory customSettings =
            _setupLaunchGroupWithStatus(launchGroupId, LaunchGroupStatus.PENDING);
        customSettings.finalizesAtParticipation = true;
        customSettings.status = LaunchGroupStatus.ACTIVE;
        vm.startPrank(manager);
        launch.setLaunchGroupSettings(launchGroupId, customSettings);
        vm.stopPrank();

        // Prepare cancel participation request
        CancelParticipationRequest memory request = _createCancelParticipationRequest();
        request.launchGroupId = launchGroupId;
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ParticipationUpdatesNotAllowed.selector, request.launchGroupId, request.launchParticipationId
            )
        );
        // Cancel participation
        launch.cancelParticipation(request, signature);
    }

    function test_RevertIf_CancelParticipation_InvalidCancelParticipationRequestUserId() public {
        // Prepare cancel participation request
        CancelParticipationRequest memory request = _createCancelParticipationRequest();
        request.userId = "invalidUserId";
        bytes memory signature = _signRequest(abi.encode(request));

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(UserIdMismatch.selector, testUserId, request.userId));
        // Cancel participation
        launch.cancelParticipation(request, signature);
    }
}

// TODO add test cases for
// _userTokensByLaunchGroupp
