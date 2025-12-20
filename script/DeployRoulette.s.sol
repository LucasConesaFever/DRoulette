// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/Roulette.sol";
import "../src/MockToken.sol";

/**
 * @title DeployRoulette
 * @notice Deployment script for DWheel Roulette contracts
 * @dev Deploys MockToken and Roulette contracts
 */
contract DeployRoulette is Script {
    // Default configuration values
    uint256 constant MIN_BET = 1 ether;
    uint256 constant MAX_BET = 100 ether;
    uint256 constant HOUSE_EDGE = 270; // 2.7%
    uint256 constant SPIN_DELAY = 60; // 60 seconds between spins
    uint256 constant INITIAL_TOKEN_SUPPLY = 1_000_000 ether;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("===========================================");
        console.log("DWheel Roulette Deployment");
        console.log("===========================================");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("===========================================");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy MockToken
        console.log("\n1. Deploying MockToken...");
        MockToken token = new MockToken(
            "DWheel Test Token",
            "DTEST",
            INITIAL_TOKEN_SUPPLY
        );
        console.log("MockToken deployed at:", address(token));
        console.log("Initial supply:", INITIAL_TOKEN_SUPPLY / 1 ether, "tokens");

        // 2. Deploy Roulette
        console.log("\n2. Deploying Roulette...");
        Roulette roulette = new Roulette(
            address(token),
            MIN_BET,
            MAX_BET,
            HOUSE_EDGE,
            SPIN_DELAY
        );
        console.log("Roulette deployed at:", address(roulette));
        console.log("Min bet:", MIN_BET / 1 ether, "tokens");
        console.log("Max bet:", MAX_BET / 1 ether, "tokens");
        console.log("House edge:", HOUSE_EDGE, "basis points");
        console.log("Spin delay:", SPIN_DELAY, "seconds");
        console.log("Initial state: OPEN (bets accepted automatically)");

        // 3. Authorize Roulette to mint and burn tokens
        console.log("\n3. Authorizing Roulette contract...");
        token.setAuthorized(address(roulette), true);
        console.log("Roulette authorized to mint/burn tokens");

        vm.stopBroadcast();

        // Print summary
        console.log("\n===========================================");
        console.log("Deployment Summary");
        console.log("===========================================");
        console.log("MockToken:", address(token));
        console.log("Roulette:", address(roulette));
        console.log("===========================================");
        console.log("\nSave these addresses to your .env file:");
        console.log("MOCK_TOKEN_ADDRESS=%s", address(token));
        console.log("ROULETTE_ADDRESS=%s", address(roulette));
        console.log("===========================================");
    }
}
