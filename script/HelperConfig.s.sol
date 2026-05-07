// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address vrfCoordinator;
        bytes32 gasLane;
        uint256 subscriptionId;
        uint32 callbackGasLimit;
        address link;
        address usdc;
        bool nativePayment;
    }

    NetworkConfig public activeNetworkConfig;

    // Sepolia configuration (VRF V2.5)
    address constant SEPOLIA_VRF_COORDINATOR = 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B;
    bytes32 constant SEPOLIA_GAS_LANE = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae; // 100 gwei
    address constant SEPOLIA_LINK = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    address constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; // Sepolia USDC

    // Mock configuration
    uint96 constant BASE_FEE = 0.1 ether; // 0.1 LINK base fee
    uint96 constant GAS_PRICE_LINK = 1e9; // 1 gwei LINK
    int256 constant WEI_PER_UNIT_LINK = 4e15; // 0.004 ETH per LINK
    uint32 constant CALLBACK_GAS_LIMIT = 500000;
    uint256 constant INITIAL_MOCK_USDC_SUPPLY = 1_000_000e6; // 1M USDC for testing

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilConfig();
        }
    }

    function getSepoliaConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            vrfCoordinator: SEPOLIA_VRF_COORDINATOR,
            gasLane: SEPOLIA_GAS_LANE,
            subscriptionId: 0, // Will be set after creating subscription
            callbackGasLimit: CALLBACK_GAS_LIMIT,
            link: SEPOLIA_LINK,
            usdc: SEPOLIA_USDC,
            nativePayment: false // Use LINK for payment on Sepolia
        });
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory) {
        // Check if we already deployed the mock
        if (activeNetworkConfig.vrfCoordinator != address(0)) {
            return activeNetworkConfig;
        }

        // Deploy mocks
        vm.startBroadcast();
        VRFCoordinatorV2_5Mock vrfCoordinatorMock = new VRFCoordinatorV2_5Mock(BASE_FEE, GAS_PRICE_LINK, WEI_PER_UNIT_LINK);
        MockUSDC mockUsdc = new MockUSDC(INITIAL_MOCK_USDC_SUPPLY);
        vm.stopBroadcast();

        return NetworkConfig({
            vrfCoordinator: address(vrfCoordinatorMock),
            gasLane: 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae, // doesn't matter for mock
            subscriptionId: 0, // Will be created in interactions script
            callbackGasLimit: CALLBACK_GAS_LIMIT,
            link: address(0), // Not needed for Anvil mock
            usdc: address(mockUsdc),
            nativePayment: true // Use native ETH for mock (simpler)
        });
    }

    function getConfig() public view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    }
}
