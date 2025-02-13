// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.22;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Test} from "forge-std/Test.sol";
import {LaunchTestBase, IERC20Events} from "./LaunchTestBase.t.sol";
import {Launch} from "../src/Launch.sol";
import {
    LaunchGroupSettings,
    LaunchGroupStatus,
    ParticipationRequest,
    CancelParticipationRequest,
    ClaimRefundRequest,
    ParticipationInfo
} from "../src/Types.sol";

contract LaunchBatchRefundTest is Test, Launch, LaunchTestBase, IERC20Events {
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

    function test_BatchRefund_SingleParticipation() public {
        // Complete the launch group
        vm.startPrank(manager);
        launch.setLaunchGroupStatus(testLaunchGroupId, LaunchGroupStatus.COMPLETED);
        vm.stopPrank();
        vm.startPrank(operator);

        ParticipationInfo memory initialInfo1 = launch.getParticipationInfo(requests[0].launchParticipationId);
        ParticipationInfo memory initialInfo2 = launch.getParticipationInfo(requests[1].launchParticipationId);
        uint256 initialCurrencyBalance = currency.balanceOf(requests[0].userAddress);
        uint256 initialCurrencyBalance2 = currency.balanceOf(requests[1].userAddress);

        // Verify RefundClaimed and Transfer events
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(launch), requests[0].userAddress, initialInfo1.currencyAmount);
        vm.expectEmit(true, true, true, true);
        emit RefundClaimed(
            testLaunchGroupId,
            requests[0].launchParticipationId,
            requests[0].userId,
            requests[0].userAddress,
            initialInfo1.currencyAmount,
            initialInfo1.currency
        );

        // Batch refund
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = requests[0].launchParticipationId;
        launch.batchRefund(testLaunchGroupId, ids);

        // Verify refund for single participation
        ParticipationInfo memory newInfo1 = launch.getParticipationInfo(requests[0].launchParticipationId);
        ParticipationInfo memory newInfo2 = launch.getParticipationInfo(requests[1].launchParticipationId);
        assertEq(newInfo1.tokenAmount, 0);
        assertEq(newInfo1.currencyAmount, 0);
        assertEq(newInfo2.tokenAmount, initialInfo2.tokenAmount);
        assertEq(newInfo2.currencyAmount, initialInfo2.currencyAmount);
        assertEq(currency.balanceOf(requests[0].userAddress), initialCurrencyBalance + initialInfo1.currencyAmount);
        assertEq(currency.balanceOf(requests[1].userAddress), initialCurrencyBalance2);

        vm.stopPrank();
    }

    function test_BatchRefund_MultipleParticipations() public {
        // Complete the launch group
        vm.startPrank(manager);
        launch.setLaunchGroupStatus(testLaunchGroupId, LaunchGroupStatus.COMPLETED);
        vm.stopPrank();

        vm.startPrank(operator);

        ParticipationInfo memory initialInfo1 = launch.getParticipationInfo(requests[0].launchParticipationId);
        ParticipationInfo memory initialInfo2 = launch.getParticipationInfo(requests[1].launchParticipationId);
        uint256 initialCurrencyBalance = currency.balanceOf(requests[0].userAddress);
        uint256 initialCurrencyBalance2 = currency.balanceOf(requests[1].userAddress);

        // Verify RefundClaimed and Transfer events
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(launch), requests[0].userAddress, initialInfo1.currencyAmount);
        vm.expectEmit(true, true, true, true);
        emit RefundClaimed(
            testLaunchGroupId,
            requests[0].launchParticipationId,
            requests[0].userId,
            requests[0].userAddress,
            initialInfo1.currencyAmount,
            initialInfo1.currency
        );
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(launch), requests[1].userAddress, initialInfo2.currencyAmount);
        vm.expectEmit(true, true, true, true);
        emit RefundClaimed(
            testLaunchGroupId,
            requests[1].launchParticipationId,
            requests[1].userId,
            requests[1].userAddress,
            initialInfo2.currencyAmount,
            initialInfo2.currency
        );

        // Batch refund
        launch.batchRefund(testLaunchGroupId, participationIds);

        // Verify refund for multiple participations
        ParticipationInfo memory newInfo1 = launch.getParticipationInfo(requests[0].launchParticipationId);
        ParticipationInfo memory newInfo2 = launch.getParticipationInfo(requests[1].launchParticipationId);
        assertEq(newInfo1.tokenAmount, 0);
        assertEq(newInfo1.currencyAmount, 0);
        assertEq(newInfo2.tokenAmount, 0);
        assertEq(newInfo2.currencyAmount, 0);
        assertEq(currency.balanceOf(requests[0].userAddress), initialCurrencyBalance + initialInfo1.currencyAmount);
        assertEq(currency.balanceOf(requests[1].userAddress), initialCurrencyBalance2 + initialInfo2.currencyAmount);

        vm.stopPrank();
    }

    function test_RevertIf_BatchRefund_LaunchPaused() public {
        vm.startPrank(admin.addr);
        launch.pause();
        vm.stopPrank();

        vm.startPrank(operator);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        // Batch refund
        launch.batchRefund(testLaunchGroupId, participationIds);
    }

    function test_RevertIf_BatchRefund_NotOperatorRole() public {
        vm.startPrank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, manager, OPERATOR_ROLE)
        );
        // Batch refund
        launch.batchRefund(testLaunchGroupId, participationIds);
    }

    function test_RevertIf_BatchRefund_InvalidLaunchGroupStatus() public {
        // Update launch group status
        vm.startPrank(manager);
        launch.setLaunchGroupStatus(testLaunchGroupId, LaunchGroupStatus.PAUSED);
        vm.stopPrank();

        vm.startPrank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidLaunchGroupStatus.selector,
                testLaunchGroupId,
                LaunchGroupStatus.COMPLETED,
                LaunchGroupStatus.PAUSED
            )
        );
        // Batch refund
        launch.batchRefund(testLaunchGroupId, participationIds);
    }

    function test_RevertIf_BatchRefund_InvalidRefundRequestIsFinalized() public {
        // Select as winner
        vm.startPrank(operator);
        launch.finalizeWinners(testLaunchGroupId, participationIds);
        vm.stopPrank();

        // Update launch group status
        vm.startPrank(manager);
        launch.setLaunchGroupStatus(testLaunchGroupId, LaunchGroupStatus.COMPLETED);
        vm.stopPrank();

        vm.startPrank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidRefundRequest.selector, requests[0].launchParticipationId, requests[0].userId)
        );
        // Batch refund
        launch.batchRefund(testLaunchGroupId, participationIds);
    }

    function test_RevertIf_BatchRefund_InvalidRefundRequestAmounts() public {
        // Cancel participation
        vm.startPrank(requests[0].userAddress);
        CancelParticipationRequest memory cancelRequest = _createCancelParticipationRequest();
        cancelRequest.userId = requests[0].userId;
        cancelRequest.userAddress = requests[0].userAddress;
        cancelRequest.launchParticipationId = requests[0].launchParticipationId;
        bytes memory cancelSignature = _signRequest(abi.encode(cancelRequest));
        launch.cancelParticipation(cancelRequest, cancelSignature);
        vm.stopPrank();

        // Update launch group status
        vm.startPrank(manager);
        launch.setLaunchGroupStatus(testLaunchGroupId, LaunchGroupStatus.COMPLETED);
        vm.stopPrank();

        vm.startPrank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidRefundRequest.selector, requests[0].launchParticipationId, requests[0].userId)
        );
        // Batch refund
        launch.batchRefund(testLaunchGroupId, participationIds);
    }

    function _createClaimRefundRequest() internal view returns (ClaimRefundRequest memory) {
        return ClaimRefundRequest({
            chainId: block.chainid,
            launchId: testLaunchId,
            launchGroupId: testLaunchGroupId,
            launchParticipationId: testLaunchParticipationId,
            userId: testUserId,
            userAddress: user1,
            requestExpiresAt: block.timestamp + 1 hours
        });
    }
}
