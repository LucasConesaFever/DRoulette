// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {Roulette} from "../src/Roulette.sol";
import {RouletteVault} from "../src/RouletteVault.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

/**
 * @title DeployAndSetupLocal
 * @notice Complete deployment and setup script for local Anvil testing
 * @dev Uses Chainlink VRF V2.5
 */
contract DeployAndSetupLocal is Script {
    uint256 constant MIN_BET = 1e6;
    uint256 constant MAX_BET = 1000e6;
    uint256 constant HOUSE_EDGE = 270;
    uint256 constant SPIN_DELAY = 10;
    uint256 constant MAX_VAULT_CAPACITY = 10_000_000e6;

    // VRF V2.5 Mock configuration
    uint96 constant BASE_FEE = 0.1 ether;
    uint96 constant GAS_PRICE_LINK = 1e9;
    int256 constant WEI_PER_UNIT_LINK = 4e15;
    uint32 constant CALLBACK_GAS_LIMIT = 500000;
    bytes32 constant GAS_LANE = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;

    uint96 constant VRF_FUND_AMOUNT = 100 ether;
    uint256 constant INITIAL_USDC_SUPPLY = 10_000_000e6;
    uint256 constant LP_DEPOSIT = 100_000e6;
    uint256 constant PLAYER_CREDITS = 1_000e6;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy VRF V2.5 Mock
        VRFCoordinatorV2_5Mock vrfCoordinator = new VRFCoordinatorV2_5Mock(BASE_FEE, GAS_PRICE_LINK, WEI_PER_UNIT_LINK);
        console.log("VRFCoordinator V2.5:", address(vrfCoordinator));

        MockUSDC usdc = new MockUSDC(INITIAL_USDC_SUPPLY);
        console.log("MockUSDC:", address(usdc));

        // Create and fund VRF subscription (V2.5 uses uint256 for subId)
        uint256 subId = vrfCoordinator.createSubscription();
        vrfCoordinator.fundSubscription(subId, VRF_FUND_AMOUNT);
        console.log("VRF SubId:", subId);

        // Deploy main contracts
        RouletteVault vault = new RouletteVault(
            address(usdc),
            "DWheel Vault Shares",
            "DWHEEL",
            MAX_VAULT_CAPACITY
        );
        console.log("Vault:", address(vault));

        Roulette roulette = new Roulette(
            address(vrfCoordinator),
            subId,
            GAS_LANE,
            CALLBACK_GAS_LIMIT,
            true, // nativePayment = true for mock
            address(vault),
            MIN_BET,
            MAX_BET,
            HOUSE_EDGE,
            SPIN_DELAY
        );
        console.log("Roulette:", address(roulette));

        // Configure
        vault.setRoulette(address(roulette));
        vrfCoordinator.addConsumer(subId, address(roulette));

        // Add liquidity
        usdc.approve(address(vault), LP_DEPOSIT);
        vault.deposit(LP_DEPOSIT, deployer);

        usdc.approve(address(vault), PLAYER_CREDITS);
        vault.depositCredits(PLAYER_CREDITS);

        vm.stopBroadcast();

        console.log("=== DEPLOYMENT COMPLETE (VRF V2.5) ===");
        console.log("USDC:", address(usdc));
        console.log("VAULT:", address(vault));
        console.log("ROULETTE:", address(roulette));
        console.log("VRF:", address(vrfCoordinator));
    }
}
