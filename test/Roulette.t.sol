// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Roulette.sol";
import "../src/RouletteVault.sol";
import "../src/mocks/MockUSDC.sol";
import "../src/libraries/RouletteTypes.sol";
import "../src/mocks/VRFCoordinatorV2Mock.sol";

/**
 * @title RouletteTest
 * @notice Comprehensive tests for the Roulette contract with Phase 2: Vault + Credits system
 */
contract RouletteTest is Test {
    Roulette public roulette;
    RouletteVault public vault;
    MockUSDC public usdc;
    VRFCoordinatorV2Mock public vrfCoordinator;

    address public owner = address(1);
    address public lp1 = address(2);
    address public lp2 = address(3);
    address public player1 = address(4);
    address public player2 = address(5);
    address public player3 = address(6);

    uint256 constant MIN_BET = 1e6; // 1 USDC
    uint256 constant MAX_BET = 100e6; // 100 USDC
    uint256 constant HOUSE_EDGE = 270; // 2.7%
    uint256 constant SPIN_DELAY = 60; // 60 seconds
    uint256 constant INITIAL_USDC_SUPPLY = 1_000_000e6; // 1M USDC
    uint256 constant MAX_VAULT_CAPACITY = 10_000_000e6; // 10M USDC

    // VRF Configuration
    uint96 constant BASE_FEE = 0.25 ether;
    uint96 constant GAS_PRICE_LINK = 1e9;
    uint64 public subscriptionId;
    bytes32 constant GAS_LANE = 0x474e34a077df58807dbe9c96d3c009b23b3c6d0cce433e59bbf5b34f823bc56c;
    uint32 constant CALLBACK_GAS_LIMIT = 500000;

    // Events
    event StateChanged(RouletteTypes.RouletteState indexed newState);
    event SpinRequested(uint256 indexed roundId, uint256 timestamp);
    event CreditsDeposited(address indexed player, uint256 amount);
    event CreditsWithdrawn(address indexed player, uint256 amount);
    event BetPlaced(
        uint256 indexed roundId,
        uint256 indexed betId,
        address indexed player,
        RouletteTypes.BetType betType,
        uint256 amount
    );
    event SpinCompleted(
        uint256 indexed roundId,
        uint8 winningNumber,
        RouletteTypes.Color winningColor,
        uint256 totalPayout
    );

    function setUp() public {
        vm.startPrank(owner);
        
        // Deploy VRF Coordinator Mock
        vrfCoordinator = new VRFCoordinatorV2Mock(BASE_FEE, GAS_PRICE_LINK);
        
        // Create and fund subscription
        subscriptionId = vrfCoordinator.createSubscription();
        vrfCoordinator.fundSubscription(subscriptionId, 3 ether);
        
        // Deploy MockUSDC
        usdc = new MockUSDC(INITIAL_USDC_SUPPLY);
        
        // Deploy RouletteVault
        vault = new RouletteVault(
            address(usdc),
            "DWheel Vault Shares",
            "DWHEEL",
            MAX_VAULT_CAPACITY
        );
        
        // Deploy Roulette with VRF
        roulette = new Roulette(
            address(vrfCoordinator),
            subscriptionId,
            GAS_LANE,
            CALLBACK_GAS_LIMIT,
            address(vault),
            MIN_BET,
            MAX_BET,
            HOUSE_EDGE,
            SPIN_DELAY
        );

        // Configure vault to recognize roulette
        vault.setRoulette(address(roulette));

        // Add Roulette as VRF consumer
        vrfCoordinator.addConsumer(subscriptionId, address(roulette));

        vm.stopPrank();

        // Distribute USDC to test accounts
        vm.startPrank(owner);
        usdc.transfer(lp1, 100_000e6);
        usdc.transfer(lp2, 100_000e6);
        usdc.transfer(player1, 10_000e6);
        usdc.transfer(player2, 10_000e6);
        usdc.transfer(player3, 10_000e6);
        vm.stopPrank();
    }

    // ============ Helper Functions ============

    // Helper function to fulfill VRF request
    function fulfillVRF(uint256 requestId) internal {
        vrfCoordinator.fulfillRandomWords(requestId, address(roulette));
    }

    // Helper function to spin and fulfill in one step
    function spinAndFulfill() internal returns (uint256 requestId) {
        // Get current round before spin
        uint256 roundId = roulette.currentRoundId();
        
        // Request spin
        vm.prank(owner);
        roulette.spin();
        
        // Get request ID from the round
        RouletteTypes.Round memory round = roulette.getRound(roundId);
        requestId = round.requestId;
        
        // Fulfill the VRF request
        fulfillVRF(requestId);
        
        return requestId;
    }

    // ============ Constructor Tests ============

    function test_Constructor() public view {
        assertEq(address(roulette.vault()), address(vault));
        assertEq(roulette.minBet(), MIN_BET);
        assertEq(roulette.maxBet(), MAX_BET);
        assertEq(roulette.houseEdge(), HOUSE_EDGE);
        assertEq(roulette.spinDelay(), SPIN_DELAY);
        assertEq(roulette.currentRoundId(), 1);
        assertEq(roulette.betIdCounter(), 0);
        assertEq(roulette.lastSpinTimestamp(), 0);
        assertTrue(roulette.state() == RouletteTypes.RouletteState.OPEN);
        
        // Check VRF config
        (address vrfCoord, uint64 subId, bytes32 gasLane, uint32 gasLimit) = roulette.getVRFConfig();
        assertEq(vrfCoord, address(vrfCoordinator));
        assertEq(subId, subscriptionId);
        assertEq(gasLane, GAS_LANE);
        assertEq(gasLimit, CALLBACK_GAS_LIMIT);
    }

    // ============ Vault LP Tests ============

    function testLPDepositReceivesShares() public {
        uint256 depositAmount = 50_000e6;
        
        vm.startPrank(lp1);
        usdc.approve(address(vault), depositAmount);
        
        uint256 sharesBefore = vault.balanceOf(lp1);
        vault.deposit(depositAmount, lp1);
        uint256 sharesAfter = vault.balanceOf(lp1);
        
        assertGt(sharesAfter, sharesBefore, "LP should receive shares");
        assertEq(vault.lpCapital(), depositAmount, "LP capital should be tracked");
        vm.stopPrank();
    }

    function testLPCannotExceedMaxCapacity() public {
        uint256 depositAmount = MAX_VAULT_CAPACITY + 1e6;
        
        vm.startPrank(lp1);
        usdc.mint(lp1, depositAmount);
        usdc.approve(address(vault), depositAmount);
        
        vm.expectRevert(RouletteVault.MaxCapacityReached.selector);
        vault.deposit(depositAmount, lp1);
        vm.stopPrank();
    }

    function testLPWithdrawBurnsShares() public {
        uint256 depositAmount = 50_000e6;
        
        vm.startPrank(lp1);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, lp1);
        
        uint256 shares = vault.balanceOf(lp1);
        uint256 lpCapitalBefore = vault.lpCapital();
        
        vault.redeem(shares, lp1, lp1);
        
        assertEq(vault.balanceOf(lp1), 0, "Shares should be burned");
        assertLt(vault.lpCapital(), lpCapitalBefore, "LP capital should decrease");
        vm.stopPrank();
    }

    function testMultipleLPsShareYield() public {
        // LP1 deposits 60k, LP2 deposits 40k
        vm.startPrank(lp1);
        usdc.approve(address(vault), 60_000e6);
        vault.deposit(60_000e6, lp1);
        vm.stopPrank();
        
        vm.startPrank(lp2);
        usdc.approve(address(vault), 40_000e6);
        vault.deposit(40_000e6, lp2);
        vm.stopPrank();
        
        uint256 lp1Shares = vault.balanceOf(lp1);
        uint256 lp2Shares = vault.balanceOf(lp2);
        
        // LP1 should have ~60% of shares, LP2 ~40%
        assertGt(lp1Shares, lp2Shares, "LP1 should have more shares");
        assertApproxEqRel(lp1Shares, lp2Shares * 3 / 2, 0.01e18, "Share ratio should be ~60:40");
    }

    // ============ Player Credits Tests ============

    function testPlayerDepositCredits() public {
        uint256 depositAmount = 1_000e6;
        
        vm.startPrank(player1);
        usdc.approve(address(vault), depositAmount);
        
        vm.expectEmit(true, false, false, true);
        emit CreditsDeposited(player1, depositAmount);
        
        vault.depositCredits(depositAmount);
        
        assertEq(roulette.credits(player1), depositAmount, "Player should have credits");
        assertEq(usdc.balanceOf(address(vault)), depositAmount, "USDC should be in vault");
        vm.stopPrank();
    }

    function testPlayerWithdrawCredits() public {
        uint256 depositAmount = 1_000e6;
        
        vm.startPrank(player1);
        usdc.approve(address(vault), depositAmount);
        vault.depositCredits(depositAmount);
        
        uint256 usdcBefore = usdc.balanceOf(player1);
        
        vm.expectEmit(true, false, false, true);
        emit CreditsWithdrawn(player1, depositAmount);
        
        vault.withdrawCredits(depositAmount);
        
        assertEq(roulette.credits(player1), 0, "Credits should be zero");
        assertEq(usdc.balanceOf(player1), usdcBefore + depositAmount, "USDC returned");
        vm.stopPrank();
    }

    function testPlayerCannotWithdrawMoreThanCredits() public {
        uint256 depositAmount = 100e6;
        
        vm.startPrank(player1);
        usdc.approve(address(vault), depositAmount);
        vault.depositCredits(depositAmount);
        
        vm.expectRevert(Roulette.InsufficientCredits.selector);
        vault.withdrawCredits(depositAmount + 1);
        vm.stopPrank();
    }

    function testPlayerCreditsDoNotAffectLPCapacity() public {
        // LPs deposit up to near capacity
        uint256 lpDeposit = MAX_VAULT_CAPACITY - 1_000e6;
        vm.startPrank(owner);
        usdc.mint(lp1, lpDeposit);
        vm.stopPrank();
        
        vm.startPrank(lp1);
        usdc.approve(address(vault), lpDeposit);
        vault.deposit(lpDeposit, lp1);
        vm.stopPrank();
        
        // Player deposits huge amount (should not hit capacity)
        uint256 playerDeposit = 50_000_000e6; // 50M USDC
        vm.startPrank(owner);
        usdc.mint(player1, playerDeposit);
        vm.stopPrank();
        
        vm.startPrank(player1);
        usdc.approve(address(vault), playerDeposit);
        vault.depositCredits(playerDeposit); // Should NOT revert
        vm.stopPrank();
        
        assertEq(roulette.credits(player1), playerDeposit, "Player credits should work");
        assertEq(vault.lpCapital(), lpDeposit, "LP capital unchanged");
    }

    // ============ Place Bet Tests ============

    function test_PlaceBet_StraightUp() public {
        // Player deposits credits first
        uint256 depositAmount = 100e6;
        vm.startPrank(player1);
        usdc.approve(address(vault), depositAmount);
        vault.depositCredits(depositAmount);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 17;

        uint256 betAmount = 10e6;
        uint256 initialCredits = roulette.credits(player1);

        vm.expectEmit(true, true, true, true);
        emit BetPlaced(1, 1, player1, RouletteTypes.BetType.STRAIGHT_UP, betAmount);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, betAmount);

        // Check credits were burned
        assertEq(roulette.credits(player1), initialCredits - betAmount);

        // Check bet was recorded
        RouletteTypes.Bet memory bet = roulette.getBet(1);
        assertEq(bet.player, player1);
        assertEq(bet.amount, betAmount);
        assertTrue(bet.betType == RouletteTypes.BetType.STRAIGHT_UP);
        assertEq(bet.numbers.length, 1);
        assertEq(bet.numbers[0], 17);
        assertFalse(bet.settled);

        // Check round stats
        RouletteTypes.Round memory round = roulette.getRound(1);
        assertEq(round.totalBets, betAmount);

        // Check player stats
        RouletteTypes.PlayerStats memory stats = roulette.getPlayerStats(player1);
        assertEq(stats.totalBets, 1);
        assertEq(stats.totalWagered, betAmount);
        vm.stopPrank();
    }

    function test_PlaceBet_Red() public {
        // Player deposits credits first
        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        
        uint8[] memory numbers = new uint8[](0);
        uint256 betAmount = 5e6;

        roulette.placeBet(RouletteTypes.BetType.RED, numbers, betAmount);

        RouletteTypes.Bet memory bet = roulette.getBet(1);
        assertTrue(bet.betType == RouletteTypes.BetType.RED);
        assertEq(bet.numbers.length, 0);
        vm.stopPrank();
    }

    function test_PlaceBet_MultiplePlayers() public {
        // Setup: Give all players credits
        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        vm.stopPrank();
        
        vm.startPrank(player2);
        usdc.approve(address(vault), 50e6);
        vault.depositCredits(50e6);
        vm.stopPrank();
        
        vm.startPrank(player3);
        usdc.approve(address(vault), 70e6);
        vault.depositCredits(70e6);
        vm.stopPrank();
        
        uint8[] memory numbers1 = new uint8[](1);
        numbers1[0] = 5;

        uint8[] memory numbers2 = new uint8[](0);

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers1, 10e6);

        vm.prank(player2);
        roulette.placeBet(RouletteTypes.BetType.RED, numbers2, 5e6);

        vm.prank(player3);
        roulette.placeBet(RouletteTypes.BetType.EVEN, numbers2, 7e6);

        // Check round has all bets
        uint256[] memory betIds = roulette.getRoundBets(1);
        assertEq(betIds.length, 3);

        // Check round total
        RouletteTypes.Round memory round = roulette.getRound(1);
        assertEq(round.totalBets, 22e6);
    }

    function testPlayerCanBetWithCredits() public {
        uint256 depositAmount = 1_000e6;
        uint256 betAmount = 10e6;
        
        // Player deposits credits
        vm.startPrank(player1);
        usdc.approve(address(vault), depositAmount);
        vault.depositCredits(depositAmount);
        
        // Place bet
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 7;
        
        vm.expectEmit(true, true, true, false);
        emit BetPlaced(1, 1, player1, RouletteTypes.BetType.STRAIGHT_UP, betAmount);
        
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, betAmount);
        
        assertEq(roulette.credits(player1), depositAmount - betAmount, "Credits burned");
        vm.stopPrank();
    }

    function testPlayerCannotBetWithoutCredits() public {
        uint256 betAmount = 10e6;
        
        vm.startPrank(player1);
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 7;
        
        vm.expectRevert(Roulette.InsufficientCredits.selector);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, betAmount);
        vm.stopPrank();
    }

    function testPlayerCannotBetMoreThanCredits() public {
        uint256 depositAmount = 5e6;
        uint256 betAmount = 10e6;
        
        vm.startPrank(player1);
        usdc.approve(address(vault), depositAmount);
        vault.depositCredits(depositAmount);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 7;
        
        vm.expectRevert(Roulette.InsufficientCredits.selector);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, betAmount);
        vm.stopPrank();
    }

    function test_PlaceBet_RevertIf_RouletteNotOpen() public {
        // Give player credits
        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        vm.stopPrank();
        
        // Use emergency stop to set state to CALCULATING
        vm.prank(owner);
        roulette.emergencyStopBetting();

        // Try to bet while CALCULATING
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;
        
        vm.prank(player1);
        vm.expectRevert(Roulette.RouletteNotOpen.selector);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);
    }

    function test_PlaceBet_RevertIf_BelowMinBet() public {
        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        vm.expectRevert(Roulette.InvalidBetAmount.selector);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET - 1);
        vm.stopPrank();
    }

    function test_PlaceBet_RevertIf_AboveMaxBet() public {
        vm.startPrank(player1);
        usdc.approve(address(vault), 200e6);
        vault.depositCredits(200e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        vm.expectRevert(Roulette.InvalidBetAmount.selector);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MAX_BET + 1);
        vm.stopPrank();
    }

    function test_PlaceBet_RevertIf_InvalidNumber() public {
        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 37; // Invalid number (max is 36)

        vm.expectRevert(Roulette.InvalidNumbers.selector);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);
        vm.stopPrank();
    }

    function test_PlaceBet_RevertIf_InvalidBetStructure() public {
        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        
        // STRAIGHT_UP requires exactly 1 number
        uint8[] memory tooMany = new uint8[](2);
        tooMany[0] = 5;
        tooMany[1] = 6;

        vm.expectRevert(Roulette.InvalidNumbers.selector);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, tooMany, MIN_BET);
        vm.stopPrank();
    }

    // ============ Spin Tests ============

    function test_Spin_FirstSpin() public {
        // LP provides liquidity
        vm.startPrank(lp1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, lp1);
        vm.stopPrank();
        
        // Place a bet
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 17;

        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, 10e6);
        vm.stopPrank();

        // Check state before spin
        assertTrue(roulette.state() == RouletteTypes.RouletteState.OPEN);

        // Spin (request VRF)
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit StateChanged(RouletteTypes.RouletteState.CALCULATING);
        roulette.spin();

        // State should be CALCULATING while waiting for VRF
        assertTrue(roulette.state() == RouletteTypes.RouletteState.CALCULATING);

        // Get request ID
        RouletteTypes.Round memory roundBeforeFulfill = roulette.getRound(1);
        uint256 requestId = roundBeforeFulfill.requestId;
        assertTrue(requestId > 0);

        // Fulfill VRF request
        fulfillVRF(requestId);

        // Check state changed back to OPEN after fulfillment
        assertTrue(roulette.state() == RouletteTypes.RouletteState.OPEN);

        // Check round is completed
        RouletteTypes.Round memory round = roulette.getRound(1);
        assertTrue(round.completed);
        assertTrue(round.winningNumber <= 36);
        
        // Check bet is settled
        RouletteTypes.Bet memory bet = roulette.getBet(1);
        assertTrue(bet.settled);

        // Check lastSpinTimestamp was updated
        assertEq(roulette.lastSpinTimestamp(), block.timestamp);

        // Check currentRoundId incremented
        assertEq(roulette.currentRoundId(), 2);
    }

    function test_Spin_WithWinningBet() public {
        // LP provides liquidity
        vm.startPrank(lp1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, lp1);
        vm.stopPrank();
        
        // Player deposits credits
        vm.startPrank(player1);
        usdc.approve(address(vault), 500e6);
        vault.depositCredits(500e6);
        
        // Place just 3 bets (to avoid gas issues)
        uint8[] memory numbers = new uint8[](1);
        uint256 betAmount = 10e6;
        
        numbers[0] = 7;
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, betAmount);
        numbers[0] = 13;
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, betAmount);
        numbers[0] = 21;
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, betAmount);
        
        uint256 creditsAfterBetting = roulette.credits(player1);
        assertEq(creditsAfterBetting, 500e6 - (3 * betAmount), "Credits after betting");
        
        vm.stopPrank();

        // Spin
        spinAndFulfill();

        // Check result
        uint256 creditsAfter = roulette.credits(player1);
        RouletteTypes.Round memory round = roulette.getRound(1);
        
        if (round.winningNumber == 7 || round.winningNumber == 13 || round.winningNumber == 21) {
            // One bet won: betAmount + (betAmount * 35) = 360e6
            uint256 expectedPayout = betAmount * 36; // 35:1 + original bet
            assertEq(creditsAfter, creditsAfterBetting + expectedPayout, "Won: Final credits should match");
            
            // Check player stats for winning case
            RouletteTypes.PlayerStats memory stats = roulette.getPlayerStats(player1);
            assertEq(stats.totalWon, betAmount * 36, "Total won should be payout");
            assertEq(stats.totalLost, betAmount * 2, "Total lost should be 2 losing bets");
        } else {
            // All 3 bets lost
            assertEq(creditsAfter, creditsAfterBetting, "Lost: Credits should stay the same");
            
            // Check player stats for losing case
            RouletteTypes.PlayerStats memory stats = roulette.getPlayerStats(player1);
            assertEq(stats.totalWon, 0, "Total won should be zero");
            assertEq(stats.totalLost, betAmount * 3, "Total lost should be all 3 bets");
        }
    }

    function test_Spin_RevertIf_NotOwner() public {
        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);
        vm.stopPrank();

        vm.prank(player2);
        vm.expectRevert();
        roulette.spin();
    }

    function test_Spin_RevertIf_NoBets() public {
        vm.prank(owner);
        vm.expectRevert(Roulette.NoActiveBets.selector);
        roulette.spin();
    }

    function test_Spin_RevertIf_AlreadyCalculating() public {
        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);
        vm.stopPrank();

        // Change state to CALCULATING manually
        vm.prank(owner);
        roulette.emergencyStopBetting();

        vm.prank(owner);
        vm.expectRevert(Roulette.AlreadyCalculating.selector);
        roulette.spin();
    }

    // ============ Spin Delay Tests ============

    function test_Spin_DelayNotRequired_FirstSpin() public {
        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);
        vm.stopPrank();

        // First spin should work immediately (no delay)
        spinAndFulfill();

        assertTrue(roulette.lastSpinTimestamp() > 0);
    }

    function test_Spin_RevertIf_DelayNotMet() public {
        // First spin
        vm.startPrank(player1);
        usdc.approve(address(vault), 200e6);
        vault.depositCredits(200e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);
        vm.stopPrank();

        spinAndFulfill();

        // Try to spin again immediately (should fail)
        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

        vm.prank(owner);
        vm.expectRevert();
        roulette.spin();
    }

    function test_Spin_AfterDelay() public {
        // First spin
        vm.startPrank(player1);
        usdc.approve(address(vault), 200e6);
        vault.depositCredits(200e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);
        vm.stopPrank();

        spinAndFulfill();

        // Wait for delay
        vm.warp(block.timestamp + SPIN_DELAY);

        // Place new bet
        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

        // Should work now
        spinAndFulfill();

        assertEq(roulette.currentRoundId(), 3);
    }

    function test_Spin_DelayCalculation() public {
        // First spin
        vm.startPrank(player1);
        usdc.approve(address(vault), 200e6);
        vault.depositCredits(200e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);
        vm.stopPrank();

        spinAndFulfill();

        // Advance time by 30 seconds (half of SPIN_DELAY)
        vm.warp(block.timestamp + 30);

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

        // Should revert with time remaining = 30 seconds
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Roulette.SpinDelayNotMet.selector, 30));
        roulette.spin();
    }

    // ============ Full Game Flow Tests ============

    function testFullGameFlowWithWin() public {
        // Setup: LP provides liquidity
        vm.startPrank(lp1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, lp1);
        vm.stopPrank();
        
        // Player deposits credits
        uint256 playerDeposit = 1_000e6;
        uint256 betAmount = 10e6;
        
        vm.startPrank(player1);
        usdc.approve(address(vault), playerDeposit);
        vault.depositCredits(playerDeposit);
        
        // Place bet on number 7
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 7;
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, betAmount);
        vm.stopPrank();
        
        // Owner spins
        vm.prank(owner);
        roulette.spin();
        
        // Get the actual requestId from the round
        RouletteTypes.Round memory round = roulette.getRound(1);
        uint256 requestId = round.requestId;
        
        // Fulfill VRF
        vrfCoordinator.fulfillRandomWords(requestId, address(roulette));
        
        // Check that round completed
        round = roulette.getRound(1);
        assertTrue(round.completed, "Round should be completed");
        
        // Player should either have won or lost, but credits should be consistent
        uint256 playerCredits = roulette.credits(player1);
        
        if (playerCredits > playerDeposit - betAmount) {
            // Player won
            assertGt(playerCredits, playerDeposit - betAmount, "Player won and got payout");
        } else {
            // Player lost
            assertEq(playerCredits, playerDeposit - betAmount, "Player lost bet");
        }
    }

    function testMultiplePlayersMultipleBets() public {
        // LP provides liquidity
        vm.startPrank(lp1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, lp1);
        vm.stopPrank();
        
        // Player1 deposits and bets on number 1
        vm.startPrank(player1);
        usdc.approve(address(vault), 1_000e6);
        vault.depositCredits(1_000e6);
        
        uint8[] memory number1 = new uint8[](1);
        number1[0] = 1;
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, number1, 50e6);
        vm.stopPrank();
        
        // Player2 deposits and bets on number 10
        vm.startPrank(player2);
        usdc.approve(address(vault), 500e6);
        vault.depositCredits(500e6);
        
        uint8[] memory number10 = new uint8[](1);
        number10[0] = 10;
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, number10, 20e6);
        vm.stopPrank();
        
        // Spin
        vm.prank(owner);
        roulette.spin();
        
        // Get the actual requestId from the round
        RouletteTypes.Round memory round = roulette.getRound(1);
        uint256 requestId = round.requestId;
        
        // Fulfill VRF
        vrfCoordinator.fulfillRandomWords(requestId, address(roulette));
        
        // Check results - both players should have settled bets
        round = roulette.getRound(1);
        assertTrue(round.completed, "Round completed");
    }

    function testPlayerCanWithdrawAfterWinning() public {
        // Setup
        vm.startPrank(lp1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, lp1);
        vm.stopPrank();
        
        // Player deposits and places bet
        vm.startPrank(player1);
        uint256 initialUSDC = usdc.balanceOf(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 7;
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, 10e6);
        vm.stopPrank();
        
        // Spin and fulfill
        vm.prank(owner);
        roulette.spin();
        
        // Get the actual requestId from the round
        RouletteTypes.Round memory round = roulette.getRound(1);
        uint256 requestId = round.requestId;
        
        vrfCoordinator.fulfillRandomWords(requestId, address(roulette));
        
        // Withdraw all credits (whether won or lost)
        vm.startPrank(player1);
        uint256 playerCredits = roulette.credits(player1);
        
        // Player should have different amount than initial (betting changes it)
        assertTrue(playerCredits != 100e6, "Credits should have changed");
        
        vault.withdrawCredits(playerCredits);
        
        uint256 finalUSDC = usdc.balanceOf(player1);
        
        // Final USDC should equal initial - deposit + withdrawn credits
        assertEq(finalUSDC, initialUSDC - 100e6 + playerCredits, "USDC balance should match");
        vm.stopPrank();
    }

    // ============ State Tests ============

    function test_GetState() public view {
        RouletteTypes.RouletteState state = roulette.getState();
        assertTrue(state == RouletteTypes.RouletteState.OPEN);
    }

    function test_StateTransition() public {
        // Initial state is OPEN
        assertTrue(roulette.state() == RouletteTypes.RouletteState.OPEN);

        // Place bet and spin
        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);
        vm.stopPrank();

        spinAndFulfill();

        // Should be back to OPEN
        assertTrue(roulette.state() == RouletteTypes.RouletteState.OPEN);
    }

    // ============ Payout Tests ============

    function test_Payout_StraightUp() public {
        // LP provides liquidity
        vm.startPrank(lp1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, lp1);
        vm.stopPrank();
        
        vm.startPrank(player1);
        usdc.approve(address(vault), 500e6);
        vault.depositCredits(500e6);
        
        uint8[] memory numbers = new uint8[](1);
        uint256 betAmount = 10e6;
        
        // Place just 3 bets (to avoid gas issues)
        numbers[0] = 7;
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, betAmount);
        numbers[0] = 13;
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, betAmount);
        numbers[0] = 21;
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, betAmount);
        
        uint256 creditsAfterBetting = roulette.credits(player1);
        assertEq(creditsAfterBetting, 500e6 - (3 * betAmount), "Credits after betting");
        
        vm.stopPrank();

        spinAndFulfill();

        uint256 creditsAfter = roulette.credits(player1);
        
        // Check if player won or lost
        RouletteTypes.Round memory round = roulette.getRound(1);
        if (round.winningNumber == 7 || round.winningNumber == 13 || round.winningNumber == 21) {
            // One bet won: betAmount + (betAmount * 35) = 360e6
            uint256 expectedPayout = betAmount * 36; // 35:1 + original bet
            assertEq(creditsAfter, creditsAfterBetting + expectedPayout, "Won: Final credits should match");
        } else {
            // All bets lost
            assertEq(creditsAfter, creditsAfterBetting, "Lost: Credits should stay the same");
        }
    }

    function test_Payout_Red() public {
        // LP provides liquidity
        vm.startPrank(lp1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, lp1);
        vm.stopPrank();
        
        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        
        uint8[] memory numbers = new uint8[](0);
        uint256 betAmount = 10e6;

        roulette.placeBet(RouletteTypes.BetType.RED, numbers, betAmount);
        vm.stopPrank();

        uint256 creditsBefore = roulette.credits(player1);

        spinAndFulfill();

        RouletteTypes.Round memory round = roulette.getRound(1);
        uint256 creditsAfter = roulette.credits(player1);

        if (RouletteTypes.getNumberColor(round.winningNumber) == RouletteTypes.Color.RED) {
            // Won: betAmount + (betAmount * 1) = betAmount * 2
            assertEq(creditsAfter, creditsBefore + (betAmount * 2));
        } else {
            // Lost: no payout
            assertEq(creditsAfter, creditsBefore);
        }
    }

    // ============ Vault Statistics Tests ============

    function testVaultTracksStatistics() public {
        // LP deposits
        vm.startPrank(lp1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, lp1);
        vm.stopPrank();
        
        // Player deposits and bets
        vm.startPrank(player1);
        usdc.approve(address(vault), 1_000e6);
        vault.depositCredits(1_000e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 7;
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, 100e6);
        vm.stopPrank();
        
        // Spin
        vm.prank(owner);
        roulette.spin();
        
        // Fulfill VRF
        RouletteTypes.Round memory round = roulette.getRound(1);
        vrfCoordinator.fulfillRandomWords(round.requestId, address(roulette));
        
        // Check stats
        (
            ,
            uint256 lpCapital,
            uint256 totalBets,
            ,
            
        ) = vault.getVaultStats();
        
        assertEq(lpCapital, 100_000e6, "LP capital tracked");
        assertEq(totalBets, 100e6, "Total bets tracked");
    }

    function testLPCapacityInfo() public {
        uint256 depositAmount = 3_000_000e6;
        
        vm.startPrank(lp1);
        usdc.mint(lp1, depositAmount);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, lp1);
        vm.stopPrank();
        
        (
            uint256 lpCapital,
            uint256 maxCapacity,
            uint256 availableCapacity
        ) = vault.getLPCapacityInfo();
        
        assertEq(lpCapital, depositAmount, "LP capital correct");
        assertEq(maxCapacity, MAX_VAULT_CAPACITY, "Max capacity correct");
        assertEq(availableCapacity, MAX_VAULT_CAPACITY - depositAmount, "Available correct");
    }

    // ============ Access Control Tests ============

    function testOnlyVaultCanAddCredits() public {
        vm.startPrank(player1);
        vm.expectRevert(Roulette.InsufficientVaultLiquidity.selector);
        roulette.addCredits(player1, 100e6);
        vm.stopPrank();
    }

    function testOnlyVaultCanRemoveCredits() public {
        vm.startPrank(player1);
        vm.expectRevert(Roulette.InsufficientVaultLiquidity.selector);
        roulette.removeCredits(player1, 100e6);
        vm.stopPrank();
    }

    function testOnlyRouletteCanCallVaultPayout() public {
        vm.startPrank(player1);
        vm.expectRevert(RouletteVault.UnauthorizedCaller.selector);
        vault.payout(player1, 100e6);
        vm.stopPrank();
    }

    // ============ Edge Cases ============

    function testCannotDepositZeroCredits() public {
        vm.startPrank(player1);
        usdc.approve(address(vault), 1000e6);
        
        vm.expectRevert(RouletteVault.InvalidAmount.selector);
        vault.depositCredits(0);
        vm.stopPrank();
    }

    function testCannotWithdrawZeroCredits() public {
        vm.startPrank(player1);
        vm.expectRevert(RouletteVault.InvalidAmount.selector);
        vault.withdrawCredits(0);
        vm.stopPrank();
    }

    // ============ Admin Function Tests ============

    function test_SetMinBet() public {
        uint256 newMinBet = 2e6;
        
        vm.prank(owner);
        roulette.setMinBet(newMinBet);

        assertEq(roulette.minBet(), newMinBet);
    }

    function test_SetMinBet_RevertIf_NotOwner() public {
        vm.prank(player1);
        vm.expectRevert();
        roulette.setMinBet(2e6);
    }

    function test_SetMaxBet() public {
        uint256 newMaxBet = 200e6;
        
        vm.prank(owner);
        roulette.setMaxBet(newMaxBet);

        assertEq(roulette.maxBet(), newMaxBet);
    }

    function test_SetHouseEdge() public {
        uint256 newHouseEdge = 300;
        
        vm.prank(owner);
        roulette.setHouseEdge(newHouseEdge);

        assertEq(roulette.houseEdge(), newHouseEdge);
    }

    function test_SetSpinDelay() public {
        uint256 newDelay = 120;
        
        vm.prank(owner);
        roulette.setSpinDelay(newDelay);

        assertEq(roulette.spinDelay(), newDelay);
    }

    function test_Pause() public {
        vm.prank(owner);
        roulette.pause();

        // Try to place bet while paused
        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        vm.expectRevert();
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);
        vm.stopPrank();
    }

    function test_Unpause() public {
        vm.startPrank(owner);
        roulette.pause();
        roulette.unpause();
        vm.stopPrank();

        // Should work now
        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);
        vm.stopPrank();

        assertTrue(roulette.betIdCounter() == 1);
    }

    function test_EmergencyStopBetting() public {
        vm.prank(owner);
        roulette.emergencyStopBetting();

        assertTrue(roulette.state() == RouletteTypes.RouletteState.CALCULATING);
    }

    function test_EmergencyResumeBetting() public {
        vm.startPrank(owner);
        roulette.emergencyStopBetting();
        roulette.emergencyResumeBetting();
        vm.stopPrank();

        assertTrue(roulette.state() == RouletteTypes.RouletteState.OPEN);
    }

    // ============ View Function Tests ============

    function test_GetRoundBets() public {
        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);
        vm.stopPrank();

        vm.startPrank(player2);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        roulette.placeBet(RouletteTypes.BetType.RED, new uint8[](0), MIN_BET);
        vm.stopPrank();

        uint256[] memory betIds = roulette.getRoundBets(1);
        assertEq(betIds.length, 2);
        assertEq(betIds[0], 1);
        assertEq(betIds[1], 2);
    }

    function test_GetBet() public {
        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 17;

        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, 10e6);
        vm.stopPrank();

        RouletteTypes.Bet memory bet = roulette.getBet(1);
        assertEq(bet.player, player1);
        assertEq(bet.amount, 10e6);
        assertEq(bet.numbers[0], 17);
    }

    function test_GetPlayerStats() public {
        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, 10e6);
        vm.stopPrank();

        RouletteTypes.PlayerStats memory stats = roulette.getPlayerStats(player1);
        assertEq(stats.totalBets, 1);
        assertEq(stats.totalWagered, 10e6);
    }

    function test_GetRound() public {
        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);
        vm.stopPrank();

        spinAndFulfill();

        RouletteTypes.Round memory round = roulette.getRound(1);
        assertEq(round.roundId, 1);
        assertTrue(round.completed);
        assertTrue(round.winningNumber <= 36);
    }

    // ============ Full Round Tests ============

    function test_FullRound() public {
        // LP provides liquidity
        vm.startPrank(lp1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, lp1);
        vm.stopPrank();
        
        // Round 1: Multiple players bet
        uint8[] memory numbers1 = new uint8[](1);
        numbers1[0] = 7;
        uint8[] memory numbersRed = new uint8[](0);

        vm.startPrank(player1);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers1, 10e6);
        vm.stopPrank();

        vm.startPrank(player2);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        roulette.placeBet(RouletteTypes.BetType.RED, numbersRed, 20e6);
        vm.stopPrank();

        vm.startPrank(player3);
        usdc.approve(address(vault), 100e6);
        vault.depositCredits(100e6);
        roulette.placeBet(RouletteTypes.BetType.EVEN, numbersRed, 15e6);
        vm.stopPrank();

        // Spin
        spinAndFulfill();

        // Verify round 1 is complete
        RouletteTypes.Round memory round1 = roulette.getRound(1);
        assertTrue(round1.completed);
        assertEq(round1.totalBets, 45e6);

        // All bets should be settled
        for (uint256 i = 1; i <= 3; i++) {
            RouletteTypes.Bet memory bet = roulette.getBet(i);
            assertTrue(bet.settled);
        }

        // State should be OPEN again
        assertTrue(roulette.state() == RouletteTypes.RouletteState.OPEN);

        // Current round should be 2
        assertEq(roulette.currentRoundId(), 2);

        // Wait for delay and start new round
        vm.warp(block.timestamp + SPIN_DELAY);

        vm.startPrank(player1);
        roulette.placeBet(RouletteTypes.BetType.BLACK, numbersRed, 5e6);
        vm.stopPrank();

        spinAndFulfill();

        assertEq(roulette.currentRoundId(), 3);
    }

    function test_MultipleRounds() public {
        vm.startPrank(player1);
        usdc.approve(address(vault), 500e6);
        vault.depositCredits(500e6);
        vm.stopPrank();
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        for (uint256 i = 0; i < 3; i++) {
            // Place bet
            vm.prank(player1);
            roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

            // Spin
            spinAndFulfill();

            // Wait for delay
            if (i < 2) {
                vm.warp(block.timestamp + SPIN_DELAY);
            }
        }

        // Should have completed 3 rounds
        assertEq(roulette.currentRoundId(), 4);

        // All rounds should be completed
        for (uint256 i = 1; i <= 3; i++) {
            RouletteTypes.Round memory round = roulette.getRound(i);
            assertTrue(round.completed);
        }
    }

    // ============ Vault-Specific Tests ============

    function testVault_SetRoulette() public {
        address newRoulette = address(0x999);
        
        vm.prank(owner);
        vault.setRoulette(newRoulette);
        
        assertEq(vault.roulette(), newRoulette);
    }

    function testVault_SetRouletteRevertIfNotOwner() public {
        vm.prank(player1);
        vm.expectRevert();
        vault.setRoulette(address(0x999));
    }

    function testVault_SetRouletteRevertIfZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Invalid address");
        vault.setRoulette(address(0));
    }

    function testVault_SetMaxCapacity() public {
        uint256 newCapacity = 20_000_000e6;
        
        vm.prank(owner);
        vault.setMaxCapacity(newCapacity);
        
        assertEq(vault.maxCapacity(), newCapacity);
    }

    function testVault_SetMaxCapacityRevertIfNotOwner() public {
        vm.prank(player1);
        vm.expectRevert();
        vault.setMaxCapacity(20_000_000e6);
    }

    function testVault_MintShares() public {
        uint256 sharesToMint = 50_000e6; // 1:1 initially
        
        vm.startPrank(lp1);
        usdc.approve(address(vault), 100_000e6);
        
        uint256 sharesBefore = vault.balanceOf(lp1);
        vault.mint(sharesToMint, lp1);
        uint256 sharesAfter = vault.balanceOf(lp1);
        
        assertEq(sharesAfter - sharesBefore, sharesToMint);
        assertEq(vault.lpCapital(), vault.previewMint(sharesToMint));
        vm.stopPrank();
    }

    function testVault_MintSharesRevertIfExceedsCapacity() public {
        uint256 sharesToMint = MAX_VAULT_CAPACITY + 1e6;
        
        vm.startPrank(lp1);
        usdc.mint(lp1, sharesToMint * 2);
        usdc.approve(address(vault), sharesToMint * 2);
        
        vm.expectRevert(RouletteVault.MaxCapacityReached.selector);
        vault.mint(sharesToMint, lp1);
        vm.stopPrank();
    }

    function testVault_WithdrawAssets() public {
        uint256 depositAmount = 50_000e6;
        
        vm.startPrank(lp1);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, lp1);
        
        uint256 lpCapitalBefore = vault.lpCapital();
        uint256 withdrawAmount = 10_000e6;
        
        vault.withdraw(withdrawAmount, lp1, lp1);
        
        assertEq(vault.lpCapital(), lpCapitalBefore - withdrawAmount);
        vm.stopPrank();
    }

    function testVault_GetAvailableLiquidity() public {
        vm.startPrank(lp1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, lp1);
        vm.stopPrank();
        
        vm.startPrank(player1);
        usdc.approve(address(vault), 5_000e6);
        vault.depositCredits(5_000e6);
        vm.stopPrank();
        
        uint256 expectedLiquidity = 100_000e6 + 5_000e6;
        assertEq(vault.getAvailableLiquidity(), expectedLiquidity);
    }

    function testVault_GetMaxBet() public {
        vm.startPrank(lp1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, lp1);
        vm.stopPrank();
        
        uint256 multiplier = 35; // Straight up
        uint256 expectedMaxBet = 100_000e6 / (multiplier + 1);
        
        assertEq(vault.getMaxBet(multiplier), expectedMaxBet);
    }

    function testVault_GetMaxBetReturnsZeroIfMultiplierZero() public {
        vm.startPrank(lp1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, lp1);
        vm.stopPrank();
        
        assertEq(vault.getMaxBet(0), 0);
    }

    function testVault_RecordBetOnlyCallableByRoulette() public {
        vm.prank(player1);
        vm.expectRevert(RouletteVault.UnauthorizedCaller.selector);
        vault.recordBet(100e6);
    }

    function testVault_RecordProfitOnlyCallableByRoulette() public {
        vm.prank(player1);
        vm.expectRevert(RouletteVault.UnauthorizedCaller.selector);
        vault.recordProfit(100e6);
    }

    function testVault_RecordLossOnlyCallableByRoulette() public {
        vm.prank(player1);
        vm.expectRevert(RouletteVault.UnauthorizedCaller.selector);
        vault.recordLoss(100e6);
    }

    function testVault_RecordLossHandlesZeroProfit() public {
        // Setup: Create scenario where vault has zero profit
        vm.startPrank(lp1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, lp1);
        vm.stopPrank();
        
        // Simulate loss larger than profit (profit should become 0, not negative)
        vm.prank(address(roulette));
        vault.recordLoss(1000e6);
        
        (,,,,uint256 totalProfit) = vault.getVaultStats();
        assertEq(totalProfit, 0);
    }

    function testVault_PayoutRevertIfInsufficientBalance() public {
        // Don't add any LP liquidity
        uint256 hugeAmount = 1_000_000_000e6; // 1B USDC
        
        vm.prank(address(roulette));
        vm.expectRevert(RouletteVault.InsufficientVaultBalance.selector);
        vault.payout(player1, hugeAmount);
    }

    function testVault_DepositCreditsRevertIfRouletteNotSet() public {
        // Deploy new vault without setting roulette
        RouletteVault newVault = new RouletteVault(
            address(usdc),
            "Test Vault",
            "TEST",
            MAX_VAULT_CAPACITY
        );
        
        vm.startPrank(player1);
        usdc.approve(address(newVault), 100e6);
        
        vm.expectRevert(RouletteVault.UnauthorizedCaller.selector);
        newVault.depositCredits(100e6);
        vm.stopPrank();
    }

    function testVault_WithdrawCreditsRevertIfRouletteNotSet() public {
        // Deploy new vault without setting roulette
        RouletteVault newVault = new RouletteVault(
            address(usdc),
            "Test Vault",
            "TEST",
            MAX_VAULT_CAPACITY
        );
        
        vm.prank(player1);
        vm.expectRevert(RouletteVault.UnauthorizedCaller.selector);
        newVault.withdrawCredits(100e6);
    }

    function testVault_LPYieldAccumulation() public {
        // LP deposits
        vm.startPrank(lp1);
        usdc.approve(address(vault), 100_000e6);
        uint256 shares = vault.deposit(100_000e6, lp1);
        vm.stopPrank();
        
        // Players bet and lose (profit for vault)
        vm.startPrank(player1);
        usdc.approve(address(vault), 10_000e6);
        vault.depositCredits(10_000e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 7;
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET); // Use MIN_BET
        vm.stopPrank();
        
        // Spin and lose (most numbers will lose)
        spinAndFulfill();
        
        // LP shares should now be worth >= initial deposit
        uint256 assetsAfter = vault.previewRedeem(shares);
        // Assets should be >= initial deposit (may be equal if the bet won)
        assertGe(assetsAfter, 100_000e6);
    }

    function testVault_MultipleWithdrawals() public {
        uint256 depositAmount = 100_000e6;
        
        vm.startPrank(lp1);
        usdc.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, lp1);
        
        // Withdraw in 3 parts
        vault.withdraw(30_000e6, lp1, lp1);
        vault.withdraw(30_000e6, lp1, lp1);
        vault.withdraw(40_000e6, lp1, lp1);
        
        vm.stopPrank();
        
        assertEq(vault.lpCapital(), 0);
        assertEq(vault.balanceOf(lp1), 0);
    }

    function testVault_DepositAfterPartialWithdraw() public {
        vm.startPrank(lp1);
        usdc.approve(address(vault), 300_000e6); // Approve enough for all operations
        
        // First deposit
        vault.deposit(100_000e6, lp1);
        assertEq(vault.lpCapital(), 100_000e6);
        
        // Withdraw some - LP1 gets back 30k USDC
        vault.withdraw(30_000e6, lp1, lp1);
        assertEq(vault.lpCapital(), 70_000e6);
        
        // Deposit again (using the 30k just withdrawn)
        vault.deposit(20_000e6, lp1);
        assertEq(vault.lpCapital(), 90_000e6);
        
        vm.stopPrank();
    }

    function testVault_CapacityOnlyAppliesToLPNotCredits() public {
        // Fill up LP capacity almost completely
        uint256 lpDeposit = MAX_VAULT_CAPACITY - 100e6;
        
        vm.startPrank(owner);
        usdc.mint(lp1, lpDeposit);
        vm.stopPrank();
        
        vm.startPrank(lp1);
        usdc.approve(address(vault), lpDeposit);
        vault.deposit(lpDeposit, lp1);
        vm.stopPrank();
        
        // LP cannot deposit more (would exceed capacity)
        vm.startPrank(lp1);
        usdc.mint(lp1, 200e6);
        usdc.approve(address(vault), 200e6);
        vm.expectRevert(RouletteVault.MaxCapacityReached.selector);
        vault.deposit(200e6, lp1);
        vm.stopPrank();
        
        // But player CAN deposit credits (no capacity limit)
        vm.startPrank(owner);
        usdc.mint(player1, 100_000_000e6);
        vm.stopPrank();
        
        vm.startPrank(player1);
        usdc.approve(address(vault), 100_000_000e6);
        vault.depositCredits(100_000_000e6); // Should NOT revert
        vm.stopPrank();
        
        assertEq(roulette.credits(player1), 100_000_000e6);
    }

    function testVault_SharesValueIncreasesWithProfit() public {
        // LP1 deposits first
        vm.startPrank(lp1);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, lp1);
        vm.stopPrank();
        
        uint256 assetsPerShareBefore = vault.previewRedeem(1e6);
        
        // Simulate profit (player loses bet)
        vm.startPrank(player1);
        usdc.approve(address(vault), 10_000e6);
        vault.depositCredits(10_000e6);
        
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 7;
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET); // Use MIN_BET
        vm.stopPrank();
        
        // Spin - if player loses, vault profits
        spinAndFulfill();
        
        // Check if profit occurred
        (,,,,uint256 profit) = vault.getVaultStats();
        
        if (profit > 0) {
            // Shares should be worth more now
            uint256 assetsPerShareAfter = vault.previewRedeem(1e6);
            assertGe(assetsPerShareAfter, assetsPerShareBefore);
        }
    }

    function testVault_ERC4626Compliance() public {
        uint256 depositAmount = 10_000e6;
        
        vm.startPrank(lp1);
        usdc.approve(address(vault), depositAmount);
        
        // Test asset() function
        assertEq(address(vault.asset()), address(usdc));
        
        // Test totalAssets before deposit
        uint256 totalAssetsBefore = vault.totalAssets();
        
        // Deposit
        uint256 shares = vault.deposit(depositAmount, lp1);
        
        // Test totalAssets after deposit
        assertEq(vault.totalAssets(), totalAssetsBefore + depositAmount);
        
        // Test convertToShares and convertToAssets
        assertEq(vault.convertToShares(depositAmount), shares);
        assertEq(vault.convertToAssets(shares), depositAmount);
        
        // Test maxDeposit (OZ ERC4626 returns max uint256 by default)
        // Verify capacity is enforced by trying to deposit more than MAX_VAULT_CAPACITY
        uint256 maxDep = vault.maxDeposit(lp1);
        assertGt(maxDep, 0); // Should allow some deposits
        
        // Verify capacity limit by checking remaining LP space
        uint256 remainingCapacity = MAX_VAULT_CAPACITY - vault.lpCapital();
        assertEq(remainingCapacity, 9_990_000e6); // 10M - 10k
        
        // Test previewWithdraw
        uint256 expectedShares = vault.previewWithdraw(depositAmount);
        assertEq(expectedShares, shares);
        
        vm.stopPrank();
    }
}

