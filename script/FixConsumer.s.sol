// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {Roulette} from "../src/Roulette.sol";
import {RouletteVault} from "../src/RouletteVault.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

contract FixConsumer is Script {
    function run() external {
        address vrfCoordinator = 0x5FbDB2315678afecb367f032d93F642f64180aa3;
        address vault = 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9;
        uint256 subId = 103069787104996898448966159236951446763654658269818536295807487104411430099941;
        bytes32 gasLane = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;

        vm.startBroadcast();

        // Deploy new Roulette
        Roulette roulette = new Roulette(
            vrfCoordinator,
            subId,
            gasLane,
            500000,
            true,
            vault,
            1e6,
            100e6,
            270,
            60
        );
        console.log("New Roulette:", address(roulette));

        // Add as consumer
        VRFCoordinatorV2_5Mock(vrfCoordinator).addConsumer(subId, address(roulette));
        console.log("Added as consumer");

        // Update vault
        RouletteVault(vault).setRoulette(address(roulette));
        console.log("Vault updated");

        vm.stopBroadcast();
    }
}
