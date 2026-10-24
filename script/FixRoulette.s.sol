// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Roulette} from "src/Roulette.sol";
import {RouletteVault} from "src/RouletteVault.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

contract FixRoulette is Script {
    function run() external {
        // Existing contracts
        address vrfCoordinator = 0x959922bE3CAee4b8Cd9a407cc3ac1C251C2007B1;
        address vault = 0xc6e7DF5E7b4f2A278906862b61205850344D4e7d;

        // New subscription ID (created fresh)
        uint256 subId = 0x39b42726042625a98b6dc38c556db246df0a16d813bbb036b85b18bee8c6b268;

        // vault.setRoulette can only be called once: this script only works on a vault with no Roulette yet.
        // To replace the Roulette of a configured vault, redeploy everything (DeployAll / DeployWithVRF).
        require(
            address(RouletteVault(vault).roulette()) == address(0),
            "Vault already has a Roulette (setRoulette is one-shot); redeploy instead"
        );

        vm.startBroadcast();

        // Deploy new Roulette with correct subscription
        Roulette roulette = new Roulette(
            vrfCoordinator,
            subId,
            0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae,
            2_500_000, // callback gas limit
            true,
            vault,
            1e6, // minBet: 1 USDC
            100e6, // maxBet: 100 USDC
            60, // spin delay: 60s
            1000, // maxExposureBps: 10%
            3600 // vrfTimeout: 1 hour
        );
        console.log("New Roulette:", address(roulette));

        // Add as consumer
        VRFCoordinatorV2_5Mock(vrfCoordinator).addConsumer(subId, address(roulette));
        console.log("Added as VRF consumer");

        // Point the vault at the new Roulette (one-shot)
        RouletteVault(vault).setRoulette(address(roulette));
        console.log("Updated vault");

        vm.stopBroadcast();

        console.log("");
        console.log("ROULETTE_ADDRESS=%s", address(roulette));
    }
}
