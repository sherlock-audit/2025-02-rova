// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.22;

import {UnsafeUpgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {LaunchTestBase} from "./LaunchTestBase.t.sol";
import {Launch} from "../src/Launch.sol";

contract LaunchInitializeTest is Test, Launch, LaunchTestBase {
    function test_Initialize() public {
        _initializeLaunch(admin.addr, testWithdrawalAddress);

        assertEq(launch.launchId(), testLaunchId);
        assertEq(launch.withdrawalAddress(), testWithdrawalAddress);
        assertTrue(launch.hasRole(launch.DEFAULT_ADMIN_ROLE(), admin.addr));
        assertTrue(launch.hasRole(launch.MANAGER_ROLE(), admin.addr));
        assertTrue(launch.hasRole(launch.OPERATOR_ROLE(), admin.addr));
        assertTrue(launch.hasRole(launch.SIGNER_ROLE(), admin.addr));
        assertTrue(launch.hasRole(launch.WITHDRAWAL_ROLE(), testWithdrawalAddress));
        assertEq(launch.getRoleAdmin(launch.WITHDRAWAL_ROLE()), launch.WITHDRAWAL_ROLE());
    }
}
