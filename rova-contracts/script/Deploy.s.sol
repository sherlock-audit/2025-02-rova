// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Upgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";
import {Script, console} from "forge-std/Script.sol";
import {Launch} from "../src/Launch.sol";

contract DeployScript is Script {
    Launch public launch;

    function setUp() public {}

    function run() public {
        address withdrawalAddress = 0x5FbDB2315678afecb367f032d93F642f64180aa3;
        bytes32 launchId = "cixf02ym000001b66m45ae4k8";
        uint8 decimals = 18;

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        console.log("Deployer address:", deployerAddress);

        vm.startBroadcast(deployerPrivateKey);

        address proxyAddress = Upgrades.deployTransparentProxy(
            "Launch.sol:Launch",
            deployerAddress,
            abi.encodeWithSelector(Launch.initialize.selector, withdrawalAddress, launchId, deployerAddress, decimals)
        );
        launch = Launch(proxyAddress);

        console.log("Proxy Launch deployed at:", proxyAddress);

        vm.stopBroadcast();
    }
}
