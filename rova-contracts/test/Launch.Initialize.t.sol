// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.22;

import {UnsafeUpgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {LaunchTestBase} from "./LaunchTestBase.t.sol";
import {Launch} from "../src/Launch.sol";

contract LaunchInitializeTest is Test, Launch, LaunchTestBase {
    function test_Initialize() public {
        vm.expectEmit(true, true, true, true);
        emit Initialized(admin.addr, testWithdrawalAddress, testLaunchId, testTokenDecimals);

        // Initialize launch
        _initializeLaunch(admin.addr, testWithdrawalAddress);

        // Verify initialization
        assertEq(launch.launchId(), testLaunchId);
        assertEq(launch.withdrawalAddress(), testWithdrawalAddress);
        assertTrue(launch.hasRole(launch.DEFAULT_ADMIN_ROLE(), admin.addr));
        assertTrue(launch.hasRole(launch.MANAGER_ROLE(), admin.addr));
        assertTrue(launch.hasRole(launch.OPERATOR_ROLE(), admin.addr));
        assertTrue(launch.hasRole(launch.SIGNER_ROLE(), admin.addr));
        assertTrue(launch.hasRole(launch.WITHDRAWAL_ROLE(), testWithdrawalAddress));
        assertEq(launch.getRoleAdmin(launch.WITHDRAWAL_ROLE()), launch.WITHDRAWAL_ROLE());
    }

    function test_RevertIf_Initialize_InvalidAdmin() public {
        address launchAddress = address(new Launch());
        vm.expectRevert();
        UnsafeUpgrades.deployTransparentProxy(
            launchAddress,
            admin.addr,
            abi.encodeWithSelector(
                Launch.initialize.selector, testWithdrawalAddress, testLaunchId, address(0), testTokenDecimals
            )
        );
    }

    function test_RevertIf_Initialize_InvalidWithdrawalAddress() public {
        address launchAddress = address(new Launch());
        vm.expectRevert();
        UnsafeUpgrades.deployTransparentProxy(
            launchAddress,
            admin.addr,
            abi.encodeWithSelector(Launch.initialize.selector, address(0), testLaunchId, admin.addr, testTokenDecimals)
        );
    }

    function test_RevertIf_Initialize_InvalidTokenDecimals() public {
        address launchAddress = address(new Launch());
        vm.expectRevert();
        UnsafeUpgrades.deployTransparentProxy(
            launchAddress,
            admin.addr,
            abi.encodeWithSelector(Launch.initialize.selector, testWithdrawalAddress, testLaunchId, admin.addr, 19)
        );
    }

    function test_RevertIf_Initialize_InvalidLaunchId() public {
        address launchAddress = address(new Launch());
        vm.expectRevert();
        UnsafeUpgrades.deployTransparentProxy(
            launchAddress,
            admin.addr,
            abi.encodeWithSelector(
                Launch.initialize.selector, testWithdrawalAddress, bytes32(0), admin.addr, testTokenDecimals
            )
        );
    }
}
