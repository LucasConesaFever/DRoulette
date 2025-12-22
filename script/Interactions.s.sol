// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {VRFCoordinatorV2Mock} from "../src/mocks/VRFCoordinatorV2Mock.sol";
import {LinkToken} from "../test/mocks/LinkToken.sol";
import {DevOpsTools} from "lib/foundry-devops/src/DevOpsTools.sol";
import {RouletteVault} from "../src/RouletteVault.sol";
import {Roulette} from "../src/Roulette.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title VRF Subscription Management Scripts
 * @notice Scripts for managing Chainlink VRF subscriptions
 */

contract CreateSubscription is Script {
    function createSubscriptionUsingConfig() public returns (uint64) {
        HelperConfig helperConfig = new HelperConfig();
        (address vrfCoordinator,,,,,) = helperConfig.activeNetworkConfig();
        return createSubscription(vrfCoordinator);
    }

    function createSubscription(address vrfCoordinator) public returns (uint64) {
        console.log("Creating subscription on ChainId: ", block.chainid);
        
        vm.startBroadcast();
        uint64 subId = VRFCoordinatorV2Mock(vrfCoordinator).createSubscription();
        vm.stopBroadcast();
        
        console.log("Your sub Id is: ", subId);
        console.log("Please update subscriptionId in HelperConfig.s.sol");
        return subId;
    }

    function run() external returns (uint64) {
        return createSubscriptionUsingConfig();
    }
}

contract FundSubscription is Script {
    uint96 public constant FUND_AMOUNT = 3 ether;

    function fundSubscriptionUsingConfig() public {
        HelperConfig helperConfig = new HelperConfig();
        (address vrfCoordinator,, uint64 subId,, address link,) = helperConfig.activeNetworkConfig();
        fundSubscription(vrfCoordinator, subId, link);
    }

    function fundSubscription(address vrfCoordinator, uint64 subId, address link) public {
        console.log("Funding subscription: ", subId);
        console.log("Using vrfCoordinator: ", vrfCoordinator);
        console.log("On ChainId: ", block.chainid);
        
        if (block.chainid == 31337) {
            // Local chain - use mock
            vm.startBroadcast();
            VRFCoordinatorV2Mock(vrfCoordinator).fundSubscription(subId, FUND_AMOUNT);
            vm.stopBroadcast();
        } else {
            // Testnet - use LINK token
            vm.startBroadcast();
            LinkToken(link).transferAndCall(vrfCoordinator, FUND_AMOUNT, abi.encode(subId));
            vm.stopBroadcast();
        }
    }

    function run() external {
        fundSubscriptionUsingConfig();
    }
}

contract AddConsumer is Script {
    function addConsumer(address roulette, address vrfCoordinator, uint64 subId) public {
        console.log("Adding consumer contract: ", roulette);
        console.log("Using vrfCoordinator: ", vrfCoordinator);
        console.log("On ChainId: ", block.chainid);
        
        vm.startBroadcast();
        VRFCoordinatorV2Mock(vrfCoordinator).addConsumer(subId, roulette);
        vm.stopBroadcast();
    }

    function addConsumerUsingConfig(address roulette) public {
        HelperConfig helperConfig = new HelperConfig();
        (address vrfCoordinator,, uint64 subId,,,) = helperConfig.activeNetworkConfig();
        addConsumer(roulette, vrfCoordinator, subId);
    }

    function run() external {
        address roulette = DevOpsTools.get_most_recent_deployment("Roulette", block.chainid);
        addConsumerUsingConfig(roulette);
    }
}

/**
 * @title Phase 2 Vault Interaction Scripts
 * @notice Scripts for interacting with RouletteVault
 */

contract DepositToVaultAsLP is Script {
    uint256 constant DEPOSIT_AMOUNT = 10_000e6; // 10,000 USDC

    function depositToVault(address vaultAddress, uint256 amount) public {
        RouletteVault vault = RouletteVault(vaultAddress);
        IERC20 usdc = IERC20(vault.asset());
        
        console.log("Depositing to vault as LP...");
        console.log("Vault:", vaultAddress);
        console.log("Amount:", amount / 1e6, "USDC");
        console.log("Sender:", msg.sender);
        
        vm.startBroadcast();
        
        // Approve vault to spend USDC
        usdc.approve(vaultAddress, amount);
        console.log("Approved vault to spend USDC");
        
        // Deposit and receive vault shares
        uint256 shares = vault.deposit(amount, msg.sender);
        
        vm.stopBroadcast();
        
        console.log("Deposited successfully!");
        console.log("Shares received:", shares / 1e6);
        console.log("LP Capital:", vault.lpCapital() / 1e6, "USDC");
    }

    function run() external {
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        depositToVault(vaultAddress, DEPOSIT_AMOUNT);
    }
}

contract DepositCreditsAsPlayer is Script {
    uint256 constant DEPOSIT_AMOUNT = 100e6; // 100 USDC

    function depositCredits(address vaultAddress, uint256 amount) public {
        RouletteVault vault = RouletteVault(vaultAddress);
        Roulette roulette = Roulette(vault.roulette());
        IERC20 usdc = IERC20(vault.asset());
        
        console.log("Depositing credits as player...");
        console.log("Vault:", vaultAddress);
        console.log("Roulette:", address(roulette));
        console.log("Amount:", amount / 1e6, "USDC");
        console.log("Sender:", msg.sender);
        
        vm.startBroadcast();
        
        // Approve vault to spend USDC
        usdc.approve(vaultAddress, amount);
        console.log("Approved vault to spend USDC");
        
        // Deposit credits (1:1 with USDC)
        vault.depositCredits(amount);
        
        vm.stopBroadcast();
        
        console.log("Credits deposited successfully!");
        console.log("Credits balance:", roulette.credits(msg.sender) / 1e6);
    }

    function run() external {
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        depositCredits(vaultAddress, DEPOSIT_AMOUNT);
    }
}

contract WithdrawCreditsAsPlayer is Script {
    uint256 constant WITHDRAW_AMOUNT = 50e6; // 50 USDC

    function withdrawCredits(address vaultAddress, uint256 amount) public {
        RouletteVault vault = RouletteVault(vaultAddress);
        Roulette roulette = Roulette(vault.roulette());
        
        console.log("Withdrawing credits as player...");
        console.log("Vault:", vaultAddress);
        console.log("Roulette:", address(roulette));
        console.log("Amount:", amount / 1e6, "USDC");
        console.log("Sender:", msg.sender);
        
        uint256 balanceBefore = roulette.credits(msg.sender);
        console.log("Credits before:", balanceBefore / 1e6);
        
        vm.startBroadcast();
        
        // Withdraw credits and receive USDC back
        vault.withdrawCredits(amount);
        
        vm.stopBroadcast();
        
        uint256 balanceAfter = roulette.credits(msg.sender);
        console.log("Credits withdrawn successfully!");
        console.log("Credits after:", balanceAfter / 1e6);
    }

    function run() external {
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        withdrawCredits(vaultAddress, WITHDRAW_AMOUNT);
    }
}

contract WithdrawFromVaultAsLP is Script {
    uint256 constant WITHDRAW_AMOUNT = 5_000e6; // 5,000 USDC

    function withdrawFromVault(address vaultAddress, uint256 amount) public {
        RouletteVault vault = RouletteVault(vaultAddress);
        
        console.log("Withdrawing from vault as LP...");
        console.log("Vault:", vaultAddress);
        console.log("Amount:", amount / 1e6, "USDC");
        console.log("Sender:", msg.sender);
        
        uint256 sharesBefore = vault.balanceOf(msg.sender);
        console.log("Shares before:", sharesBefore / 1e6);
        
        vm.startBroadcast();
        
        // Withdraw assets and burn shares
        uint256 sharesBurned = vault.withdraw(amount, msg.sender, msg.sender);
        
        vm.stopBroadcast();
        
        uint256 sharesAfter = vault.balanceOf(msg.sender);
        console.log("Withdrawn successfully!");
        console.log("Shares burned:", sharesBurned / 1e6);
        console.log("Shares after:", sharesAfter / 1e6);
        console.log("LP Capital:", vault.lpCapital() / 1e6, "USDC");
    }

    function run() external {
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        withdrawFromVault(vaultAddress, WITHDRAW_AMOUNT);
    }
}

contract GetVaultInfo is Script {
    function getVaultInfo(address vaultAddress) public view {
        RouletteVault vault = RouletteVault(vaultAddress);
        
        console.log("\n===========================================");
        console.log("RouletteVault Information");
        console.log("===========================================");
        console.log("Vault Address:", vaultAddress);
        console.log("Asset (USDC):", vault.asset());
        console.log("Roulette:", vault.roulette());
        
        // LP Information
        console.log("\n--- LP Information ---");
        console.log("LP Capital:", vault.lpCapital() / 1e6, "USDC");
        console.log("Total Supply (Shares):", vault.totalSupply() / 1e6);
        console.log("Max Capacity:", vault.maxCapacity() / 1e6, "USDC");
        console.log("Available Liquidity:", vault.getAvailableLiquidity() / 1e6, "USDC");
        
        // Statistics
        console.log("\n--- Statistics ---");
        (
            uint256 totalBetsPlaced,
            uint256 totalBetsAmount,
            uint256 totalPayouts,
            uint256 totalLosses,
            uint256 totalProfit
        ) = vault.getVaultStats();
        console.log("Total Bets Placed:", totalBetsPlaced);
        console.log("Total Bets Amount:", totalBetsAmount / 1e6, "USDC");
        console.log("Total Payouts:", totalPayouts / 1e6, "USDC");
        console.log("Total Losses:", totalLosses / 1e6, "USDC");
        console.log("Total Profit:", totalProfit / 1e6, "USDC");
        
        // Risk Management
        console.log("\n--- Risk Management ---");
        console.log("Max Bet (35x multiplier):", vault.getMaxBet(35) / 1e6, "USDC");
        console.log("Max Bet (2x multiplier):", vault.getMaxBet(2) / 1e6, "USDC");
        
        console.log("===========================================\n");
    }

    function run() external view {
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        getVaultInfo(vaultAddress);
    }
}
