// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.22;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";
import {LaunchTestBase} from "./LaunchTestBase.t.sol";
import {Launch} from "../src/Launch.sol";
import {
    LaunchGroupSettings,
    LaunchGroupStatus,
    ParticipationRequest,
    CancelParticipationRequest,
    ParticipationInfo
} from "../src/Types.sol";

contract LaunchfinalizeWinnersTest is Test, Launch, LaunchTestBase {
    LaunchGroupSettings public settings;
    ParticipationRequest[] public requests;

    bytes32[] public participationIds;
    address[] public users;

    function setUp() public {
        _setUpLaunch();

        settings = _setupLaunchGroup();

        // Setup multiple participations
        participationIds = new bytes32[](2);
        participationIds[0] = bytes32(uint256(1));
        participationIds[1] = bytes32(uint256(2));
        users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        requests = _setupParticipations(participationIds, users);
    }

    function test_FinalizeWinners() public {
        vm.startPrank(operator);

        // Verify WinnerSelected events
        vm.expectEmit(true, true, true, true);
        emit WinnerSelected(
            testLaunchGroupId, requests[0].launchParticipationId, requests[0].userId, requests[0].userAddress
        );
        vm.expectEmit(true, true, true, true);
        emit WinnerSelected(
            testLaunchGroupId, requests[1].launchParticipationId, requests[1].userId, requests[1].userAddress
        );

        // Select winners
        launch.finalizeWinners(testLaunchGroupId, participationIds);

        // Verify winners
        ParticipationInfo[] memory infos = new ParticipationInfo[](participationIds.length);
        for (uint256 i = 0; i < participationIds.length; i++) {
            ParticipationInfo memory info = launch.getParticipationInfo(participationIds[i]);
            assertTrue(info.isFinalized);
            infos[i] = info;
        }

        // Verify tokens sold
        uint256 currTotalTokensSold = launch.getTokensSoldByLaunchGroup(testLaunchGroupId);
        assertEq(currTotalTokensSold, requests[0].tokenAmount + requests[1].tokenAmount);

        // Verify withdrawable amount
        assertEq(
            launch.getWithdrawableAmountByCurrency(address(currency)), infos[0].currencyAmount + infos[1].currencyAmount
        );

        vm.stopPrank();
    }

    function test_FinalizeWinners_AllowFinalizeWinnersForDifferentLaunchGroupId() public {
        // Create new launch group
        bytes32 launchGroupId = bytes32(uint256(1));
        _setupLaunchGroupWithStatus(launchGroupId, LaunchGroupStatus.ACTIVE);

        vm.startPrank(operator);

        // Verify WinnerSelected events
        vm.expectEmit(true, true, true, true);
        emit WinnerSelected(
            launchGroupId, requests[0].launchParticipationId, requests[0].userId, requests[0].userAddress
        );
        vm.expectEmit(true, true, true, true);
        emit WinnerSelected(
            launchGroupId, requests[1].launchParticipationId, requests[1].userId, requests[1].userAddress
        );

        // Select winners
        launch.finalizeWinners(launchGroupId, participationIds);

        // Verify winners
        ParticipationInfo[] memory infos = new ParticipationInfo[](participationIds.length);
        for (uint256 i = 0; i < participationIds.length; i++) {
            ParticipationInfo memory info = launch.getParticipationInfo(participationIds[i]);
            assertTrue(info.isFinalized);
            infos[i] = info;
        }

        // Verify tokens sold
        uint256 currTotalTokensSold = launch.getTokensSoldByLaunchGroup(launchGroupId);
        assertEq(currTotalTokensSold, requests[0].tokenAmount + requests[1].tokenAmount);

        // Verify withdrawable amount
        assertEq(
            launch.getWithdrawableAmountByCurrency(address(currency)), infos[0].currencyAmount + infos[1].currencyAmount
        );

        vm.stopPrank();
    }

    function test_RevertIf_FinalizeWinners_InvalidLaunchGroupStatus() public {
        // Update launch group status
        vm.startPrank(manager);
        launch.setLaunchGroupStatus(testLaunchGroupId, LaunchGroupStatus.COMPLETED);
        vm.stopPrank();

        vm.startPrank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidLaunchGroupStatus.selector,
                testLaunchGroupId,
                LaunchGroupStatus.ACTIVE,
                LaunchGroupStatus.COMPLETED
            )
        );
        // Select winners
        launch.finalizeWinners(testLaunchGroupId, participationIds);
    }

    function test_RevertIf_FinalizeWinners_NotOperatorRole() public {
        vm.startPrank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, manager, OPERATOR_ROLE)
        );
        // Select winners
        launch.finalizeWinners(testLaunchGroupId, participationIds);
    }

    function test_RevertIf_FinalizeWinners_LaunchGroupFinalizesAtParticipation() public {
        // Setup new launch group
        bytes32 launchGroupId = bytes32(uint256(1));
        LaunchGroupSettings memory customSettings =
            _setupLaunchGroupWithStatus(launchGroupId, LaunchGroupStatus.PENDING);
        customSettings.finalizesAtParticipation = true;
        customSettings.status = LaunchGroupStatus.ACTIVE;
        vm.startPrank(manager);
        launch.setLaunchGroupSettings(launchGroupId, customSettings);
        vm.stopPrank();

        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(LaunchGroupFinalizesAtParticipation.selector, launchGroupId));
        // Select winners
        launch.finalizeWinners(launchGroupId, participationIds);
    }

    function test_RevertIf_FinalizeWinners_InvalidWinnerZeroAmounts() public {
        // Cancel participation
        vm.startPrank(requests[0].userAddress);
        CancelParticipationRequest memory request = _createCancelParticipationRequest();
        request.userAddress = requests[0].userAddress;
        request.userId = requests[0].userId;
        request.launchParticipationId = requests[0].launchParticipationId;
        bytes memory signature = _signRequest(abi.encode(request));
        launch.cancelParticipation(request, signature);
        vm.stopPrank();

        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(InvalidWinner.selector, participationIds[0], requests[0].userId));
        // Select winners
        launch.finalizeWinners(testLaunchGroupId, participationIds);
    }

    function test_RevertIf_FinalizeWinners_MaxTokenAllocationReached() public {
        // Update max token allocation
        vm.startPrank(manager);
        settings.maxTokenAllocation = 1000 * 10 ** launch.tokenDecimals();
        launch.setLaunchGroupSettings(testLaunchGroupId, settings);
        vm.stopPrank();

        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(MaxTokenAllocationReached.selector, testLaunchGroupId));
        // Select winners
        launch.finalizeWinners(testLaunchGroupId, participationIds);
    }
}
