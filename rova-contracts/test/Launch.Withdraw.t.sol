// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.22;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Test} from "forge-std/Test.sol";
import {LaunchTestBase, IERC20Events} from "./LaunchTestBase.t.sol";
import {Launch} from "../src/Launch.sol";
import {LaunchGroupSettings, LaunchGroupStatus} from "../src/Types.sol";

contract LaunchWithdrawTest is Test, Launch, LaunchTestBase, IERC20Events {
    function setUp() public {
        _setUpLaunch();

        LaunchGroupSettings memory settings = _setupLaunchGroupWithStatus(testLaunchGroupId, LaunchGroupStatus.PENDING);
        settings.status = LaunchGroupStatus.ACTIVE;
        settings.finalizesAtParticipation = true;
        vm.startPrank(manager);
        launch.setLaunchGroupSettings(testLaunchGroupId, settings);
        vm.stopPrank();

        // Setup multiple participations
        bytes32[] memory participationIds = new bytes32[](2);
        participationIds[0] = bytes32(uint256(1));
        participationIds[1] = bytes32(uint256(2));
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        _setupParticipations(participationIds, users);

        // Complete the launch group
        vm.startPrank(manager);
        launch.setLaunchGroupStatus(testLaunchGroupId, LaunchGroupStatus.COMPLETED);
        vm.stopPrank();
    }

    function test_Withdraw_FullAmount() public {
        uint256 withdrawableAmount = launch.getWithdrawableAmountByCurrency(address(currency));
        assertEq(currency.balanceOf(testWithdrawalAddress), 0);
        assertEq(currency.balanceOf(address(launch)), withdrawableAmount);

        vm.startPrank(testWithdrawalAddress);
        // Verify events
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(launch), testWithdrawalAddress, withdrawableAmount);
        vm.expectEmit(true, true, true, true);
        emit Withdrawal(testWithdrawalAddress, address(currency), withdrawableAmount);

        // Withdraw
        launch.withdraw(address(currency), withdrawableAmount);

        assertEq(currency.balanceOf(testWithdrawalAddress), withdrawableAmount);
        assertEq(currency.balanceOf(address(launch)), 0);
        assertEq(launch.getWithdrawableAmountByCurrency(address(currency)), 0);
    }

    function test_Withdraw_PartialAmount() public {
        uint256 withdrawableAmount = launch.getWithdrawableAmountByCurrency(address(currency));
        assertEq(currency.balanceOf(testWithdrawalAddress), 0);
        assertEq(currency.balanceOf(address(launch)), withdrawableAmount);
        uint256 withdrawAmount = withdrawableAmount * 1 / 4;

        vm.startPrank(testWithdrawalAddress);
        // Verify events
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(launch), testWithdrawalAddress, withdrawAmount);
        vm.expectEmit(true, true, true, true);
        emit Withdrawal(testWithdrawalAddress, address(currency), withdrawAmount);

        // Withdraw
        launch.withdraw(address(currency), withdrawAmount);

        assertEq(currency.balanceOf(testWithdrawalAddress), withdrawAmount);
        assertEq(currency.balanceOf(address(launch)), withdrawableAmount - withdrawAmount);
        assertEq(launch.getWithdrawableAmountByCurrency(address(currency)), withdrawableAmount - withdrawAmount);
    }

    function test_RevertIf_Withdraw_LaunchPaused() public {
        vm.startPrank(admin.addr);
        launch.pause();
        vm.stopPrank();

        vm.startPrank(testWithdrawalAddress);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        // Withdraw
        launch.withdraw(address(currency), 1);
    }

    function test_RevertIf_Withdraw_NotWithdrawalRole() public {
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, WITHDRAWAL_ROLE)
        );
        // Withdraw
        launch.withdraw(address(currency), 1);
    }

    function test_RevertIf_Withdraw_InvalidLaunchGroupStatus() public {
        // Create new launch group
        bytes32 launchGroupId = bytes32(uint256(1));
        _setupLaunchGroupWithStatus(launchGroupId, LaunchGroupStatus.PENDING);

        vm.startPrank(testWithdrawalAddress);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidLaunchGroupStatus.selector, launchGroupId, LaunchGroupStatus.COMPLETED, LaunchGroupStatus.PENDING
            )
        );
        // Withdraw
        launch.withdraw(address(currency), 1);
    }

    function test_RevertIf_Withdraw_InvalidWithdrawalAmount() public {
        uint256 withdrawableAmount = launch.getWithdrawableAmountByCurrency(address(currency));
        uint256 withdrawAmount = withdrawableAmount + 1;

        vm.startPrank(testWithdrawalAddress);
        vm.expectRevert(abi.encodeWithSelector(InvalidWithdrawalAmount.selector, withdrawAmount, withdrawableAmount));
        // Withdraw
        launch.withdraw(address(currency), withdrawAmount);
    }
}
