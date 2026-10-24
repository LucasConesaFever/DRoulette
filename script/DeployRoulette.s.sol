// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Roulette} from "src/Roulette.sol";
import {RouletteVault} from "src/RouletteVault.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

/**
 * @title DeployRoulette
 * @notice Deployment script for DWheel Roulette Phase 2 with Vault and Credits
 * @dev Deploys MockUSDC (or uses real USDC), RouletteVault, and Roulette
 *      Uses Chainlink VRF V2.5
 */
contract DeployRoulette is Script {
    // Default configuration values
    uint256 constant MIN_BET = 1e6; // 1 USDC (6 decimals)
    uint256 constant MAX_BET = 100e6; // 100 USDC
    uint256 constant SPIN_DELAY = 60; // 60 seconds between spins
    uint256 constant MAX_VAULT_CAPACITY = 10_000_000e6; // 10M USDC cap
    uint256 constant MAX_EXPOSURE_BPS = 1000; // 10% of vault assets per round
    uint256 constant VRF_TIMEOUT = 3600; // 1 hour before the owner can refund a stuck round

    function run() external returns (Roulette, RouletteVault, address, HelperConfig) {
        // Get network configuration
        HelperConfig helperConfig = new HelperConfig();
        (
            address vrfCoordinator,
            bytes32 gasLane,
            uint256 subscriptionId,
            uint32 callbackGasLimit,, // link
            address usdc,
            bool nativePayment
        ) = helperConfig.activeNetworkConfig();

        console.log("===========================================");
        console.log("DWheel Roulette Phase 2 Deployment (VRF V2.5)");
        console.log("===========================================");
        console.log("Chain ID:", block.chainid);
        console.log("VRF Coordinator:", vrfCoordinator);
        console.log("Subscription ID:", subscriptionId);
        console.log("USDC Address:", usdc);
        console.log("Native Payment:", nativePayment);
        console.log("===========================================");

        // Start broadcast - uses --account flag from CLI or PRIVATE_KEY env var
        vm.startBroadcast();

        // 1. USDC is already deployed (from config or mock)
        console.log("\n1. Using USDC at:", usdc);
        if (block.chainid == 31337) {
            console.log("(MockUSDC deployed via HelperConfig)");
        } else {
            console.log("(Using real USDC on", block.chainid, ")");
        }

        // 2. Deploy RouletteVault (ERC4626)
        console.log("\n2. Deploying RouletteVault (ERC4626)...");
        RouletteVault vault = new RouletteVault(usdc, "DWheel Vault Shares", "DWHEEL", MAX_VAULT_CAPACITY);
        console.log("RouletteVault deployed at:", address(vault));
        console.log("Max capacity:", MAX_VAULT_CAPACITY / 1e6, "USDC");

        // 3. Deploy Roulette with VRF V2.5 and Vault
        console.log("\n3. Deploying Roulette with VRF V2.5...");
        Roulette roulette = new Roulette(
            vrfCoordinator,
            subscriptionId,
            gasLane,
            callbackGasLimit,
            nativePayment,
            address(vault),
            MIN_BET,
            MAX_BET,
            SPIN_DELAY,
            MAX_EXPOSURE_BPS,
            VRF_TIMEOUT
        );
        console.log("Roulette deployed at:", address(roulette));
        console.log("Min bet:", MIN_BET / 1e6, "USDC");
        console.log("Max bet:", MAX_BET / 1e6, "USDC");
        console.log("Spin delay:", SPIN_DELAY, "seconds");
        console.log("Max exposure:", MAX_EXPOSURE_BPS, "bps of vault assets");
        console.log("VRF timeout:", VRF_TIMEOUT, "seconds");
        console.log("Callback gas limit:", callbackGasLimit);

        // 4. Configure vault to recognize Roulette
        console.log("\n4. Setting Roulette as authorized in Vault (one-shot)...");
        vault.setRoulette(address(roulette));
        console.log("Roulette authorized in Vault");

        vm.stopBroadcast();

        // Print summary
        console.log("\n===========================================");
        console.log("Deployment Summary - Phase 2 (VRF V2.5)");
        console.log("===========================================");
        console.log("USDC:", usdc);
        console.log("RouletteVault:", address(vault));
        console.log("Roulette:", address(roulette));
        console.log("VRF Coordinator:", vrfCoordinator);
        console.log("===========================================");
        console.log("\nNEXT STEPS:");
        if (subscriptionId == 0) {
            console.log("1. Create VRF V2.5 subscription:");
            console.log(
                "   forge script script/Interactions.s.sol:CreateSubscription --rpc-url $RPC_URL --account <name> --broadcast"
            );
            console.log("2. Fund the subscription at https://vrf.chain.link or with script:");
            console.log(
                "   forge script script/Interactions.s.sol:FundSubscription --rpc-url $RPC_URL --account <name> --broadcast"
            );
            console.log("3. Add Roulette as consumer:");
            console.log(
                "   forge script script/Interactions.s.sol:AddConsumer --rpc-url $RPC_URL --account <name> --broadcast"
            );
        }
        console.log("\nPhase 2 System:");
        console.log("- Players: usdc.approve(roulette) + roulette.depositCredits(USDC) -> get credits (1:1)");
        console.log("- Players: roulette.withdrawCredits() -> get USDC back");
        console.log("- LPs: vault.deposit(USDC) -> get vault shares (earn yield)");
        console.log("- Player USDC stays in Roulette; only net round results move to/from the vault");
        console.log("\nSave these addresses to your .env file:");
        console.log("USDC_ADDRESS=%s", usdc);
        console.log("VAULT_ADDRESS=%s", address(vault));
        console.log("ROULETTE_ADDRESS=%s", address(roulette));
        console.log("===========================================");

        return (roulette, vault, usdc, helperConfig);
    }
}
