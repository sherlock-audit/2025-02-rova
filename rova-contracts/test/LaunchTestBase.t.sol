// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.22;

import {UnsafeUpgrades} from "@openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {Launch} from "../src/Launch.sol";
import {
    CurrencyConfig,
    LaunchGroupSettings,
    LaunchGroupStatus,
    ParticipationRequest,
    CancelParticipationRequest
} from "../src/Types.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }
}

interface IERC20Events {
    event Transfer(address indexed from, address indexed to, uint256 value);
}

abstract contract LaunchTestBase is Test, Launch {
    Launch public launch;
    MockERC20 public currency;

    VmSafe.Wallet public admin = vm.createWallet("admin");
    address public manager = address(1);
    address public operator = address(2);
    address public signer = address(3);
    address public testWithdrawalAddress = address(4);
    address public user1 = address(5);
    address public user2 = address(6);

    // Dummy cuids for testing
    bytes32 public testLaunchId = "cixf02ym000001b66m45ae4k8";
    bytes32 public testLaunchGroupId = "ch72gsb320000udocl363eofy";
    bytes32 public testLaunchParticipationId = "cm6o2sldi00003b74facm5z9n";
    bytes32 public testUserId = "cm6o2tm1300003b74dsss1s7q";

    function _setUpLaunch() public {
        vm.startPrank(admin.addr);

        // Deploy contracts
        _initializeLaunch(admin.addr, testWithdrawalAddress);
        currency = new MockERC20();

        // Setup roles
        launch.grantRole(MANAGER_ROLE, manager);
        launch.grantRole(OPERATOR_ROLE, operator);
        launch.grantRole(SIGNER_ROLE, signer);

        // Fund users
        currency.transfer(user1, 2000 * 10 ** launch.tokenDecimals());
        currency.transfer(user2, 1000 * 10 ** launch.tokenDecimals());
        vm.stopPrank();
    }

    // Helper functions
    function _setupLaunchGroup() internal returns (LaunchGroupSettings memory) {
        return _setupLaunchGroupWithStatus(testLaunchGroupId, LaunchGroupStatus.ACTIVE);
    }

    function _setupLaunchGroupWithStatus(bytes32 launchGroupId, LaunchGroupStatus status)
        internal
        returns (LaunchGroupSettings memory)
    {
        CurrencyConfig memory currencyConfig =
            CurrencyConfig({tokenPriceBps: 1 * 10 ** currency.decimals(), isEnabled: true});
        LaunchGroupSettings memory settings = LaunchGroupSettings({
            finalizesAtParticipation: false,
            startsAt: block.timestamp,
            endsAt: block.timestamp + 1 days,
            maxTokenAllocation: 10000 * 10 ** launch.tokenDecimals(),
            minTokenAmountPerUser: 500 * 10 ** launch.tokenDecimals(),
            maxTokenAmountPerUser: 3000 * 10 ** launch.tokenDecimals(),
            status: status
        });
        vm.startPrank(manager);
        launch.createLaunchGroup(launchGroupId, address(currency), currencyConfig, settings);
        vm.stopPrank();
        return settings;
    }

    function _updateLaunchGroupSettings(LaunchGroupSettings memory settings) internal {
        vm.startPrank(manager);
        launch.setLaunchGroupSettings(testLaunchGroupId, settings);
        vm.stopPrank();
    }

    function _createParticipationRequest() internal view returns (ParticipationRequest memory) {
        return ParticipationRequest({
            chainId: block.chainid,
            launchId: testLaunchId,
            launchGroupId: testLaunchGroupId,
            launchParticipationId: testLaunchParticipationId,
            userId: testUserId,
            userAddress: user1,
            tokenAmount: 1000 * 10 ** launch.tokenDecimals(),
            currency: address(currency),
            requestExpiresAt: block.timestamp + 1 hours
        });
    }

    function _signRequest(bytes memory encodedRequest) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(encodedRequest);
        bytes32 messageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(admin.privateKey, messageHash);
        return abi.encodePacked(r, s, v);
    }

    function _signRequestWithSigner(bytes memory encodedRequest, uint256 privateKey)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(encodedRequest);
        bytes32 messageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, messageHash);
        return abi.encodePacked(r, s, v);
    }

    function _setupParticipations(bytes32[] memory participationIds, address[] memory users)
        internal
        returns (ParticipationRequest[] memory)
    {
        ParticipationRequest[] memory requests = new ParticipationRequest[](participationIds.length);
        for (uint256 i = 0; i < participationIds.length; i++) {
            ParticipationRequest memory request = ParticipationRequest({
                chainId: block.chainid,
                launchId: testLaunchId,
                launchGroupId: testLaunchGroupId,
                launchParticipationId: participationIds[i],
                userId: bytes32(uint256(i + 1)),
                userAddress: users[i],
                tokenAmount: 1000 * 10 ** launch.tokenDecimals(),
                currency: address(currency),
                requestExpiresAt: block.timestamp + 1 hours
            });

            bytes memory signature = _signRequest(abi.encode(request));

            vm.startPrank(users[i]);
            currency.approve(
                address(launch), _getCurrencyAmount(request.launchGroupId, request.currency, request.tokenAmount)
            );
            launch.participate(request, signature);
            vm.stopPrank();

            requests[i] = request;
        }
        return requests;
    }

    function _createCancelParticipationRequest() internal view returns (CancelParticipationRequest memory) {
        return CancelParticipationRequest({
            chainId: block.chainid,
            launchId: testLaunchId,
            launchGroupId: testLaunchGroupId,
            launchParticipationId: testLaunchParticipationId,
            userId: testUserId,
            userAddress: user1,
            requestExpiresAt: block.timestamp + 1 hours
        });
    }

    function _getCurrencyAmount(bytes32 launchGroupId, address currencyAddress, uint256 tokenAmount)
        internal
        view
        returns (uint256)
    {
        uint256 tokenPriceBps = launch.getLaunchGroupCurrencyConfig(launchGroupId, currencyAddress).tokenPriceBps;
        return Math.mulDiv(tokenPriceBps, tokenAmount, 10 ** launch.tokenDecimals());
    }

    function _initializeLaunch(address adminAddress, address withdrawalAddress) internal {
        address proxyAddress = UnsafeUpgrades.deployTransparentProxy(
            address(new Launch()),
            adminAddress,
            abi.encodeWithSelector(Launch.initialize.selector, withdrawalAddress, testLaunchId, adminAddress, 18)
        );
        launch = Launch(proxyAddress);
    }
}
