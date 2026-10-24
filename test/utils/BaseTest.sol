// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {Roulette} from "src/Roulette.sol";
import {RouletteVault} from "src/RouletteVault.sol";
import {RouletteTypes} from "src/libraries/RouletteTypes.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

/**
 * @title BaseTest
 * @notice Shared deployment and helpers for Roulette / RouletteVault tests
 */
abstract contract BaseTest is Test {
    Roulette internal roulette;
    RouletteVault internal vault;
    MockUSDC internal usdc;
    VRFCoordinatorV2_5Mock internal vrfCoordinator;
    uint256 internal subscriptionId;

    address internal owner = makeAddr("owner");
    address internal lp1 = makeAddr("lp1");
    address internal lp2 = makeAddr("lp2");
    address internal player1 = makeAddr("player1");
    address internal player2 = makeAddr("player2");
    address internal player3 = makeAddr("player3");

    uint256 internal constant MIN_BET = 1e6; // 1 USDC
    uint256 internal constant MAX_BET = 100e6; // 100 USDC
    uint256 internal constant HOUSE_EDGE = 270;
    uint256 internal constant SPIN_DELAY = 60;
    uint256 internal constant MAX_EXPOSURE_BPS = 1_000; // 10%
    uint256 internal constant VRF_TIMEOUT = 1 hours;
    uint256 internal constant MAX_VAULT_CAPACITY = 10_000_000e6;
    uint32 internal constant CALLBACK_GAS_LIMIT = 2_500_000;
    uint256 internal constant LP_LIQUIDITY = 100_000e6;

    // VRF V2.5 mock configuration
    uint96 internal constant BASE_FEE = 0.1 ether;
    uint96 internal constant GAS_PRICE_LINK = 1e9;
    int256 internal constant WEI_PER_UNIT_LINK = 4e15;
    bytes32 internal constant GAS_LANE = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;

    // Winning numbers used by tests: word % 37 gives the number
    uint256 internal constant RED_NUMBER = 1;
    uint256 internal constant BLACK_NUMBER = 2;
    uint256 internal constant ZERO = 0;

    function setUp() public virtual {
        vm.startPrank(owner);
        vrfCoordinator = new VRFCoordinatorV2_5Mock(BASE_FEE, GAS_PRICE_LINK, WEI_PER_UNIT_LINK);
        subscriptionId = vrfCoordinator.createSubscription();
        vrfCoordinator.fundSubscription(subscriptionId, 1_000_000 ether);

        usdc = new MockUSDC(0);
        vault = new RouletteVault(address(usdc), "DWheel Vault Shares", "DWHEEL", MAX_VAULT_CAPACITY);
        roulette = new Roulette(
            address(vrfCoordinator),
            subscriptionId,
            GAS_LANE,
            CALLBACK_GAS_LIMIT,
            false,
            address(vault),
            MIN_BET,
            MAX_BET,
            HOUSE_EDGE,
            SPIN_DELAY,
            MAX_EXPOSURE_BPS,
            VRF_TIMEOUT
        );
        vault.setRoulette(address(roulette));
        vrfCoordinator.addConsumer(subscriptionId, address(roulette));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    function _lpDeposit(address lp, uint256 amount) internal returns (uint256 shares) {
        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount, lp);
        vm.stopPrank();
    }

    function _fundCredits(address player, uint256 amount) internal {
        usdc.mint(player, amount);
        vm.startPrank(player);
        usdc.approve(address(roulette), amount);
        roulette.depositCredits(amount);
        vm.stopPrank();
    }

    function _bet(address player, RouletteTypes.BetType betType, uint8[] memory numbers, uint256 amount) internal {
        vm.prank(player);
        roulette.placeBet(betType, numbers, amount);
    }

    function _betRed(address player, uint256 amount) internal {
        _bet(player, RouletteTypes.BetType.RED, new uint8[](0), amount);
    }

    function _betBlack(address player, uint256 amount) internal {
        _bet(player, RouletteTypes.BetType.BLACK, new uint8[](0), amount);
    }

    function _betStraight(address player, uint8 number, uint256 amount) internal {
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = number;
        _bet(player, RouletteTypes.BetType.STRAIGHT_UP, numbers, amount);
    }

    /// @dev Requests a spin (waiting out the spin delay) and returns the VRF request id
    function _spin() internal returns (uint256 requestId) {
        vm.warp(block.timestamp + SPIN_DELAY + 1);
        uint256 roundId = roulette.currentRoundId();
        vm.prank(owner);
        roulette.spin();
        requestId = roulette.getRound(roundId).requestId;
    }

    /// @dev Fulfills a VRF request through the mock, with the real callback gas limit
    function _fulfill(uint256 requestId, uint256 winningNumber) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = winningNumber;
        vrfCoordinator.fulfillRandomWordsWithOverride(requestId, address(roulette), words);
    }

    function _spinAndFulfill(uint256 winningNumber) internal returns (uint256 roundId) {
        roundId = roulette.currentRoundId();
        _fulfill(_spin(), winningNumber);
    }

    /// @dev Roulette solvency: its USDC backs all credits plus the open round's stakes, minus any deficit
    function _assertRouletteSolvent() internal view {
        uint256 openStakes;
        RouletteTypes.Round memory round = roulette.getRound(roulette.currentRoundId());
        if (!round.completed) openStakes = round.totalBets;
        assertGe(
            usdc.balanceOf(address(roulette)) + roulette.deficit(),
            roulette.totalCredits() + openStakes,
            "roulette insolvent"
        );
    }
}
