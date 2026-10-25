// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {Roulette} from "src/Roulette.sol";
import {RouletteVault} from "src/RouletteVault.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

/**
 * @title DeployLocalVrf
 * @notice Step 1 of the local Anvil deployment: VRF V2.5 mock and subscription
 * @dev The mock derives the subscription id from blockhash(block.number - 1), so the id forge simulates
 *      differs from the one created on-chain, and Roulette needs the real id in its constructor.
 *      DeployAndSetupLocal reads it from the chain in a second run. script/deploy-local.sh runs both.
 */
contract DeployLocalVrf is Script {
    uint96 constant BASE_FEE = 0.1 ether;
    uint96 constant GAS_PRICE_LINK = 1e9;
    int256 constant WEI_PER_UNIT_LINK = 4e15;

    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        VRFCoordinatorV2_5Mock vrfCoordinator = new VRFCoordinatorV2_5Mock(BASE_FEE, GAS_PRICE_LINK, WEI_PER_UNIT_LINK);
        vrfCoordinator.createSubscription();
        vm.stopBroadcast();

        console.log("VRF_COORDINATOR:", address(vrfCoordinator));
    }
}

/**
 * @title DeployAndSetupLocal
 * @notice Step 2 of the local Anvil deployment: USDC, vault and Roulette, funded and configured
 * @dev Needs VRF_COORDINATOR from DeployLocalVrf; uses the deployer's latest subscription on it.
 */
contract DeployAndSetupLocal is Script {
    uint256 constant MIN_BET = 1e6;
    uint256 constant MAX_BET = 1000e6;
    uint256 constant SPIN_DELAY = 10;
    uint256 constant MAX_VAULT_CAPACITY = 10_000_000e6;
    uint256 constant MAX_EXPOSURE_BPS = 1000; // 10% of vault assets per round
    uint256 constant VRF_TIMEOUT = 3600; // 1 hour before the owner can refund a stuck round

    uint32 constant CALLBACK_GAS_LIMIT = 2_500_000;
    bytes32 constant GAS_LANE = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;

    uint256 constant VRF_FUND_AMOUNT = 100 ether; // native: the mock charges ~0.1 ETH per fulfillment
    uint256 constant INITIAL_USDC_SUPPLY = 10_000_000e6;
    uint256 constant LP_DEPOSIT = 100_000e6;
    uint256 constant PLAYER_CREDITS = 1_000e6;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        VRFCoordinatorV2_5Mock vrfCoordinator = VRFCoordinatorV2_5Mock(vm.envAddress("VRF_COORDINATOR"));
        uint256 subId = _latestSubscription(vrfCoordinator, deployer);

        console.log("Deployer:", deployer);
        console.log("VRF SubId:", subId);

        vm.startBroadcast(deployerPrivateKey);

        // Roulette asks for native payment, so fund the native balance: a LINK-only balance makes every
        // fulfillment revert
        vrfCoordinator.fundSubscriptionWithNative{value: VRF_FUND_AMOUNT}(subId);

        MockUSDC usdc = new MockUSDC(INITIAL_USDC_SUPPLY);
        RouletteVault vault = new RouletteVault(address(usdc), "DWheel Vault Shares", "DWHEEL", MAX_VAULT_CAPACITY);
        Roulette roulette = new Roulette(
            address(vrfCoordinator),
            subId,
            GAS_LANE,
            CALLBACK_GAS_LIMIT,
            true, // nativePayment
            address(vault),
            MIN_BET,
            MAX_BET,
            SPIN_DELAY,
            MAX_EXPOSURE_BPS,
            VRF_TIMEOUT
        );

        // Configure
        vault.setRoulette(address(roulette));
        vrfCoordinator.addConsumer(subId, address(roulette));

        // Add liquidity
        usdc.approve(address(vault), LP_DEPOSIT);
        vault.deposit(LP_DEPOSIT, deployer);

        // Player credits live in Roulette
        usdc.approve(address(roulette), PLAYER_CREDITS);
        roulette.depositCredits(PLAYER_CREDITS);

        vm.stopBroadcast();

        console.log("=== DEPLOYMENT COMPLETE (VRF V2.5) ===");
        console.log("USDC:", address(usdc));
        console.log("VAULT:", address(vault));
        console.log("ROULETTE:", address(roulette));
        console.log("VRF:", address(vrfCoordinator));
    }

    function _latestSubscription(VRFCoordinatorV2_5Mock vrfCoordinator, address owner)
        internal
        view
        returns (uint256 subId)
    {
        uint256[] memory ids = vrfCoordinator.getActiveSubscriptionIds(0, 0);
        for (uint256 i = ids.length; i > 0; --i) {
            (,,, address subOwner,) = vrfCoordinator.getSubscription(ids[i - 1]);
            if (subOwner == owner) return ids[i - 1];
        }
        revert("No subscription: run DeployLocalVrf first");
    }
}
