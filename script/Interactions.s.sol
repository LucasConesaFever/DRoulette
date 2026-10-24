// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {DevOpsTools} from "lib/foundry-devops/src/DevOpsTools.sol";
import {RouletteVault} from "src/RouletteVault.sol";
import {Roulette} from "src/Roulette.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title VRF Subscription Management Scripts
 * @notice Scripts for managing Chainlink VRF subscriptions
 */

contract CreateSubscription is Script {
    function createSubscriptionUsingConfig() public returns (uint256) {
        HelperConfig helperConfig = new HelperConfig();
        (address vrfCoordinator,,,,,,) = helperConfig.activeNetworkConfig();
        return createSubscription(vrfCoordinator);
    }

    function createSubscription(address vrfCoordinator) public returns (uint256) {
        console.log("Creating subscription on ChainId: ", block.chainid);

        vm.startBroadcast();
        uint256 subId = VRFCoordinatorV2_5Mock(vrfCoordinator).createSubscription();
        vm.stopBroadcast();

        console.log("Your sub Id is: ", subId);
        console.log("Please update subscriptionId in HelperConfig.s.sol");
        return subId;
    }

    function run() external returns (uint256) {
        return createSubscriptionUsingConfig();
    }
}

contract FundSubscription is Script {
    uint96 public constant FUND_AMOUNT = 3 ether;

    function fundSubscriptionUsingConfig() public {
        HelperConfig helperConfig = new HelperConfig();
        (address vrfCoordinator,, uint256 subId,, address link,,) = helperConfig.activeNetworkConfig();
        fundSubscription(vrfCoordinator, subId, link);
    }

    function fundSubscription(address vrfCoordinator, uint256 subId, address link) public {
        console.log("Funding subscription: ", subId);
        console.log("Using vrfCoordinator: ", vrfCoordinator);
        console.log("On ChainId: ", block.chainid);

        if (block.chainid == 31337) {
            // Local chain - use mock
            vm.startBroadcast();
            VRFCoordinatorV2_5Mock(vrfCoordinator).fundSubscription(subId, FUND_AMOUNT);
            vm.stopBroadcast();
        } else {
            // Testnet - use LINK token
            vm.startBroadcast();
            LinkTokenInterface(link).transferAndCall(vrfCoordinator, FUND_AMOUNT, abi.encode(subId));
            vm.stopBroadcast();
        }
    }

    function run() external {
        fundSubscriptionUsingConfig();
    }
}

contract AddConsumer is Script {
    function addConsumer(address roulette, address vrfCoordinator, uint256 subId) public {
        console.log("Adding consumer contract: ", roulette);
        console.log("Using vrfCoordinator: ", vrfCoordinator);
        console.log("On ChainId: ", block.chainid);

        vm.startBroadcast();
        VRFCoordinatorV2_5Mock(vrfCoordinator).addConsumer(subId, roulette);
        vm.stopBroadcast();
    }

    function addConsumerUsingConfig(address roulette) public {
        HelperConfig helperConfig = new HelperConfig();
        (address vrfCoordinator,, uint256 subId,,,,) = helperConfig.activeNetworkConfig();
        addConsumer(roulette, vrfCoordinator, subId);
    }

    function run() external {
        address roulette = DevOpsTools.get_most_recent_deployment("Roulette", block.chainid);
        addConsumerUsingConfig(roulette);
    }
}

/**
 * @title Vault and Credits Interaction Scripts
 * @notice LPs use RouletteVault (ERC4626). Players deposit/withdraw credits on Roulette.
 */

contract DepositToVaultAsLP is Script {
    uint256 constant DEPOSIT_AMOUNT = 10_000e6; // 10,000 USDC

    function depositToVault(address vaultAddress, uint256 amount) public {
        RouletteVault vault = RouletteVault(vaultAddress);
        IERC20 usdc = IERC20(vault.asset());
        uint256 shareUnit = 10 ** vault.decimals();

        console.log("Depositing to vault as LP...");
        console.log("Vault:", vaultAddress);
        console.log("Amount:", amount / 1e6, "USDC");
        console.log("Sender:", msg.sender);
        console.log("Max deposit:", vault.maxDeposit(msg.sender) / 1e6, "USDC");
        console.log("LP locked:", vault.isLpLocked());

        vm.startBroadcast();

        // Approve vault to spend USDC
        usdc.approve(vaultAddress, amount);
        console.log("Approved vault to spend USDC");

        // Deposit and receive vault shares
        uint256 shares = vault.deposit(amount, msg.sender);

        vm.stopBroadcast();

        console.log("Deposited successfully!");
        console.log("Shares received:", shares / shareUnit);
        console.log("Total assets:", vault.totalAssets() / 1e6, "USDC");
    }

    function run() external {
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        depositToVault(vaultAddress, DEPOSIT_AMOUNT);
    }
}

contract DepositCreditsAsPlayer is Script {
    uint256 constant DEPOSIT_AMOUNT = 100e6; // 100 USDC

    function depositCredits(address rouletteAddress, uint256 amount) public {
        Roulette roulette = Roulette(rouletteAddress);
        IERC20 usdc = roulette.usdc();

        console.log("Depositing credits as player...");
        console.log("Roulette:", rouletteAddress);
        console.log("Amount:", amount / 1e6, "USDC");
        console.log("Sender:", msg.sender);

        vm.startBroadcast();

        // Approve Roulette to spend USDC (player funds live in Roulette)
        usdc.approve(rouletteAddress, amount);
        console.log("Approved Roulette to spend USDC");

        // Deposit credits (1:1 with USDC)
        roulette.depositCredits(amount);

        vm.stopBroadcast();

        console.log("Credits deposited successfully!");
        console.log("Credits balance:", roulette.credits(msg.sender) / 1e6);
    }

    function run() external {
        address rouletteAddress = vm.envAddress("ROULETTE_ADDRESS");
        depositCredits(rouletteAddress, DEPOSIT_AMOUNT);
    }
}

contract WithdrawCreditsAsPlayer is Script {
    uint256 constant WITHDRAW_AMOUNT = 50e6; // 50 USDC

    function withdrawCredits(address rouletteAddress, uint256 amount) public {
        Roulette roulette = Roulette(rouletteAddress);

        console.log("Withdrawing credits as player...");
        console.log("Roulette:", rouletteAddress);
        console.log("Amount:", amount / 1e6, "USDC");
        console.log("Sender:", msg.sender);

        uint256 balanceBefore = roulette.credits(msg.sender);
        console.log("Credits before:", balanceBefore / 1e6);

        vm.startBroadcast();

        // Withdraw credits and receive USDC back
        roulette.withdrawCredits(amount);

        vm.stopBroadcast();

        uint256 balanceAfter = roulette.credits(msg.sender);
        console.log("Credits withdrawn successfully!");
        console.log("Credits after:", balanceAfter / 1e6);
    }

    function run() external {
        address rouletteAddress = vm.envAddress("ROULETTE_ADDRESS");
        withdrawCredits(rouletteAddress, WITHDRAW_AMOUNT);
    }
}

contract WithdrawFromVaultAsLP is Script {
    uint256 constant WITHDRAW_AMOUNT = 5_000e6; // 5,000 USDC

    function withdrawFromVault(address vaultAddress, uint256 amount) public {
        RouletteVault vault = RouletteVault(vaultAddress);
        uint256 shareUnit = 10 ** vault.decimals();

        console.log("Withdrawing from vault as LP...");
        console.log("Vault:", vaultAddress);
        console.log("Amount:", amount / 1e6, "USDC");
        console.log("Sender:", msg.sender);
        console.log("Max withdraw:", vault.maxWithdraw(msg.sender) / 1e6, "USDC");
        console.log("LP locked:", vault.isLpLocked());

        uint256 sharesBefore = vault.balanceOf(msg.sender);
        console.log("Shares before:", sharesBefore / shareUnit);

        vm.startBroadcast();

        // Withdraw assets and burn shares
        uint256 sharesBurned = vault.withdraw(amount, msg.sender, msg.sender);

        vm.stopBroadcast();

        uint256 sharesAfter = vault.balanceOf(msg.sender);
        console.log("Withdrawn successfully!");
        console.log("Shares burned:", sharesBurned / shareUnit);
        console.log("Shares after:", sharesAfter / shareUnit);
        console.log("Total assets:", vault.totalAssets() / 1e6, "USDC");
    }

    function run() external {
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        withdrawFromVault(vaultAddress, WITHDRAW_AMOUNT);
    }
}

contract GetVaultInfo is Script {
    function getVaultInfo(address vaultAddress) public view {
        RouletteVault vault = RouletteVault(vaultAddress);
        Roulette roulette = Roulette(address(vault.roulette()));
        uint8 shareDecimals = vault.decimals();

        console.log("\n===========================================");
        console.log("RouletteVault Information");
        console.log("===========================================");
        console.log("Vault Address:", vaultAddress);
        console.log("Asset (USDC):", vault.asset());
        console.log("Roulette:", address(roulette));

        // LP Information (standard ERC4626 views)
        console.log("\n--- LP Information ---");
        console.log("Total Assets:", vault.totalAssets() / 1e6, "USDC");
        console.log("Total Supply (raw shares):", vault.totalSupply());
        console.log("Share decimals:", shareDecimals);
        console.log("Assets per 1 share (raw USDC):", vault.convertToAssets(10 ** shareDecimals));
        console.log("Max Capacity:", vault.maxCapacity() / 1e6, "USDC");
        console.log("Max Deposit:", vault.maxDeposit(address(0)) / 1e6, "USDC");
        console.log("LP Locked:", vault.isLpLocked());
        console.log("LP Lock Override:", vault.lpLockOverride());

        if (address(roulette) == address(0)) {
            console.log("===========================================\n");
            return;
        }

        // House statistics (tracked by Roulette)
        console.log("\n--- House Statistics ---");
        (uint256 wagered, uint256 paidOut, int256 netPnl) = roulette.getHouseStats();
        console.log("Total Wagered:", wagered / 1e6, "USDC");
        console.log("Total Paid Out:", paidOut / 1e6, "USDC");
        console.log("House Net PnL (raw USDC):", netPnl);
        console.log("Player Credits (USDC in Roulette):", roulette.getTotalCredits() / 1e6, "USDC");

        // Risk Management
        console.log("\n--- Risk Management ---");
        console.log("State (0=OPEN 1=CALCULATING 2=DEFICIT):", uint256(roulette.getState()));
        console.log("Max Bet:", roulette.maxBet() / 1e6, "USDC");
        console.log("Max Exposure (bps of vault assets):", roulette.maxExposureBps());
        console.log("Max Bets per Round:", roulette.MAX_BETS_PER_ROUND());
        console.log("Reserved Liquidity:", roulette.reservedLiquidity() / 1e6, "USDC");
        console.log("Deficit:", roulette.deficit() / 1e6, "USDC");
        console.log("VRF Timeout:", roulette.vrfTimeout(), "seconds");

        console.log("===========================================\n");
    }

    function run() external view {
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        getVaultInfo(vaultAddress);
    }
}
