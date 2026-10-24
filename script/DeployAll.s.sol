// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Roulette} from "src/Roulette.sol";
import {RouletteVault} from "src/RouletteVault.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

contract DeployAll is Script {
    function run() external {
        // Anvil default account #0 (public, well-known test key). Local Anvil only, never use on a real network.
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy VRF Coordinator Mock
        VRFCoordinatorV2_5Mock vrfCoordinator = new VRFCoordinatorV2_5Mock(
            0.1 ether, // baseFee
            1e9, // gasPriceLink
            4e15 // weiPerUnitLink
        );
        console.log("VRF:", address(vrfCoordinator));

        vm.stopBroadcast();

        // 2. Create subscription (separate broadcast to ensure VRF is deployed)
        vm.startBroadcast(deployerPrivateKey);

        uint256 subId = vrfCoordinator.createSubscription();
        console.log("SubID:", subId);

        vrfCoordinator.fundSubscriptionWithNative{value: 10 ether}(subId);
        console.log("Funded subscription");

        // 3. Deploy MockUSDC
        MockUSDC usdc = new MockUSDC(1_000_000e6);
        console.log("USDC:", address(usdc));

        // 4. Deploy Vault
        RouletteVault vault = new RouletteVault(address(usdc), "DWheel Vault Shares", "DWHEEL", 10_000_000e6);
        console.log("Vault:", address(vault));

        // 5. Deploy Roulette
        Roulette roulette = new Roulette(
            address(vrfCoordinator),
            subId,
            bytes32(0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae),
            2_500_000, // callbackGasLimit
            true,
            address(vault),
            1e6,
            100e6,
            60,
            1000, // maxExposureBps: 10%
            3600 // vrfTimeout: 1 hour
        );
        console.log("Roulette:", address(roulette));

        // 6. Configure
        vrfCoordinator.addConsumer(subId, address(roulette));
        console.log("Added consumer");

        vault.setRoulette(address(roulette));
        console.log("Set roulette in vault");

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("USDC:", address(usdc));
        console.log("VAULT:", address(vault));
        console.log("ROULETTE:", address(roulette));
        console.log("VRF:", address(vrfCoordinator));
    }
}
