// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Roulette} from "src/Roulette.sol";
import {RouletteVault} from "src/RouletteVault.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

contract DeployWithVRF is Script {
    uint256 constant MIN_BET = 1e6;
    uint256 constant MAX_BET = 100e6;
    uint256 constant SPIN_DELAY = 60;
    uint256 constant MAX_VAULT_CAPACITY = 10_000_000e6;
    uint256 constant MAX_EXPOSURE_BPS = 1000; // 10% of vault assets per round
    uint256 constant VRF_TIMEOUT = 3600; // 1 hour before the owner can refund a stuck round

    uint96 constant BASE_FEE = 0.1 ether;
    uint96 constant GAS_PRICE_LINK = 1e9;
    int256 constant WEI_PER_UNIT_LINK = 4e15;
    uint32 constant CALLBACK_GAS_LIMIT = 2_500_000;
    bytes32 constant GAS_LANE = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;

    function run() external {
        vm.startBroadcast();

        // 1. Deploy VRF Coordinator Mock
        VRFCoordinatorV2_5Mock vrfCoordinator = new VRFCoordinatorV2_5Mock(BASE_FEE, GAS_PRICE_LINK, WEI_PER_UNIT_LINK);
        console.log("VRF Coordinator:", address(vrfCoordinator));

        // 2. Create and fund subscription
        uint256 subId = vrfCoordinator.createSubscription();
        vrfCoordinator.fundSubscriptionWithNative{value: 10 ether}(subId);
        console.log("Subscription ID:", subId);

        // 3. Deploy MockUSDC
        MockUSDC usdc = new MockUSDC(1_000_000e6);
        console.log("USDC:", address(usdc));

        // 4. Deploy Vault
        RouletteVault vault = new RouletteVault(address(usdc), "DWheel Vault Shares", "DWHEEL", MAX_VAULT_CAPACITY);
        console.log("Vault:", address(vault));

        // 5. Deploy Roulette WITH correct subscription ID
        Roulette roulette = new Roulette(
            address(vrfCoordinator),
            subId,
            GAS_LANE,
            CALLBACK_GAS_LIMIT,
            true, // nativePayment for Anvil
            address(vault),
            MIN_BET,
            MAX_BET,
            SPIN_DELAY,
            MAX_EXPOSURE_BPS,
            VRF_TIMEOUT
        );
        console.log("Roulette:", address(roulette));

        // 6. Add consumer and configure vault
        vrfCoordinator.addConsumer(subId, address(roulette));
        vault.setRoulette(address(roulette));

        vm.stopBroadcast();

        console.log("");
        console.log("=========================================");
        console.log("Deployment Complete!");
        console.log("=========================================");
        console.log("USDC_ADDRESS=%s", address(usdc));
        console.log("VAULT_ADDRESS=%s", address(vault));
        console.log("ROULETTE_ADDRESS=%s", address(roulette));
        console.log("VRF_COORDINATOR=%s", address(vrfCoordinator));
        console.log("=========================================");
    }
}
