// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Roulette.sol";
import "../src/MockToken.sol";
import "../src/libraries/RouletteTypes.sol";

/**
 * @title RouletteTest
 * @notice Comprehensive tests for the Roulette contract
 */
contract RouletteTest is Test {
    Roulette public roulette;
    MockToken public token;

    address public owner = address(1);
    address public player1 = address(2);
    address public player2 = address(3);
    address public player3 = address(4);

    uint256 constant MIN_BET = 1 ether;
    uint256 constant MAX_BET = 100 ether;
    uint256 constant HOUSE_EDGE = 270; // 2.7%
    uint256 constant SPIN_DELAY = 60; // 60 seconds
    uint256 constant INITIAL_BALANCE = 1000 ether;

    event StateChanged(RouletteTypes.RouletteState indexed newState);
    event SpinRequested(uint256 indexed roundId, uint256 timestamp);
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
        
        // Deploy MockToken
        token = new MockToken("Test Token", "TEST", 0);
        
        // Deploy Roulette
        roulette = new Roulette(
            address(token),
            MIN_BET,
            MAX_BET,
            HOUSE_EDGE,
            SPIN_DELAY
        );

        // Authorize roulette to mint and burn
        token.setAuthorized(address(roulette), true);

        vm.stopPrank();

        // Setup players with initial balances
        vm.startPrank(player1);
        token.faucet(INITIAL_BALANCE);
        vm.stopPrank();

        vm.startPrank(player2);
        token.faucet(INITIAL_BALANCE);
        vm.stopPrank();

        vm.startPrank(player3);
        token.faucet(INITIAL_BALANCE);
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor() public view {
        assertEq(address(roulette.bettingToken()), address(token));
        assertEq(roulette.minBet(), MIN_BET);
        assertEq(roulette.maxBet(), MAX_BET);
        assertEq(roulette.houseEdge(), HOUSE_EDGE);
        assertEq(roulette.spinDelay(), SPIN_DELAY);
        assertEq(roulette.currentRoundId(), 1);
        assertEq(roulette.betIdCounter(), 0);
        assertEq(roulette.lastSpinTimestamp(), 0);
        assertTrue(roulette.state() == RouletteTypes.RouletteState.OPEN);
    }

    // ============ Place Bet Tests ============

    function test_PlaceBet_StraightUp() public {
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 17;

        uint256 betAmount = 10 ether;
        uint256 initialBalance = token.balanceOf(player1);

        vm.prank(player1);
        vm.expectEmit(true, true, true, true);
        emit BetPlaced(1, 1, player1, RouletteTypes.BetType.STRAIGHT_UP, betAmount);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, betAmount);

        // Check balance was burned
        assertEq(token.balanceOf(player1), initialBalance - betAmount);

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
    }

    function test_PlaceBet_Red() public {
        uint8[] memory numbers = new uint8[](0);
        uint256 betAmount = 5 ether;

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.RED, numbers, betAmount);

        RouletteTypes.Bet memory bet = roulette.getBet(1);
        assertTrue(bet.betType == RouletteTypes.BetType.RED);
        assertEq(bet.numbers.length, 0);
    }

    function test_PlaceBet_MultiplePlayers() public {
        uint8[] memory numbers1 = new uint8[](1);
        numbers1[0] = 5;

        uint8[] memory numbers2 = new uint8[](0);

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers1, 10 ether);

        vm.prank(player2);
        roulette.placeBet(RouletteTypes.BetType.RED, numbers2, 5 ether);

        vm.prank(player3);
        roulette.placeBet(RouletteTypes.BetType.EVEN, numbers2, 7 ether);

        // Check round has all bets
        uint256[] memory betIds = roulette.getRoundBets(1);
        assertEq(betIds.length, 3);

        // Check round total
        RouletteTypes.Round memory round = roulette.getRound(1);
        assertEq(round.totalBets, 22 ether);
    }

    function test_PlaceBet_RevertIf_RouletteNotOpen() public {
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
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        vm.prank(player1);
        vm.expectRevert(Roulette.InvalidBetAmount.selector);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET - 1);
    }

    function test_PlaceBet_RevertIf_AboveMaxBet() public {
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        vm.prank(player1);
        vm.expectRevert(Roulette.InvalidBetAmount.selector);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MAX_BET + 1);
    }

    function test_PlaceBet_RevertIf_InvalidNumber() public {
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 37; // Invalid number (max is 36)

        vm.prank(player1);
        vm.expectRevert(Roulette.InvalidNumbers.selector);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);
    }

    function test_PlaceBet_RevertIf_InvalidBetStructure() public {
        // STRAIGHT_UP requires exactly 1 number
        uint8[] memory tooMany = new uint8[](2);
        tooMany[0] = 5;
        tooMany[1] = 6;

        vm.prank(player1);
        vm.expectRevert(Roulette.InvalidNumbers.selector);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, tooMany, MIN_BET);
    }

    // ============ Spin Tests ============

    function test_Spin_FirstSpin() public {
        // Place a bet
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 17;

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, 10 ether);

        // Spin
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit StateChanged(RouletteTypes.RouletteState.CALCULATING);
        roulette.spin();

        // Check state changed back to OPEN
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
        // Place bets on ALL numbers to guarantee a win
        uint8[] memory numbers = new uint8[](1);
        uint256 betAmount = 1 ether;
        
        for (uint8 i = 0; i <= 36; i++) {
            numbers[0] = i;
            vm.prank(player1);
            roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, betAmount);
        }

        uint256 balanceBefore = token.balanceOf(player1);

        // Spin
        vm.prank(owner);
        roulette.spin();

        // Player should have won exactly once (one bet wins, 36 lose)
        uint256 balanceAfter = token.balanceOf(player1);
        uint256 expectedWin = betAmount + (betAmount * 35); // Straight up pays 35:1
        
        assertEq(balanceAfter, balanceBefore + expectedWin);

        // Check player stats
        RouletteTypes.PlayerStats memory stats = roulette.getPlayerStats(player1);
        assertEq(stats.totalWon, expectedWin);
        assertEq(stats.totalLost, betAmount * 36); // 36 losing bets
    }

    function test_Spin_RevertIf_NotOwner() public {
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

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
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

        // Change state to CALCULATING manually
        vm.prank(owner);
        roulette.emergencyStopBetting();

        vm.prank(owner);
        vm.expectRevert(Roulette.AlreadyCalculating.selector);
        roulette.spin();
    }

    // ============ Spin Delay Tests ============

    function test_Spin_DelayNotRequired_FirstSpin() public {
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

        // First spin should work immediately (no delay)
        vm.prank(owner);
        roulette.spin();

        assertTrue(roulette.lastSpinTimestamp() > 0);
    }

    function test_Spin_RevertIf_DelayNotMet() public {
        // First spin
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

        vm.prank(owner);
        roulette.spin();

        // Try to spin again immediately (should fail)
        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

        vm.prank(owner);
        vm.expectRevert();
        roulette.spin();
    }

    function test_Spin_AfterDelay() public {
        // First spin
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

        vm.prank(owner);
        roulette.spin();

        // Wait for delay
        vm.warp(block.timestamp + SPIN_DELAY);

        // Place new bet
        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

        // Should work now
        vm.prank(owner);
        roulette.spin();

        assertEq(roulette.currentRoundId(), 3);
    }

    function test_Spin_DelayCalculation() public {
        // First spin
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

        uint256 firstSpinTime = block.timestamp;
        vm.prank(owner);
        roulette.spin();

        // Advance time by 30 seconds (half of SPIN_DELAY)
        vm.warp(block.timestamp + 30);

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

        // Should revert with time remaining = 30 seconds
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Roulette.SpinDelayNotMet.selector, 30));
        roulette.spin();
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
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

        vm.prank(owner);
        roulette.spin();

        // Should be back to OPEN
        assertTrue(roulette.state() == RouletteTypes.RouletteState.OPEN);
    }

    // ============ Payout Tests ============

    function test_Payout_StraightUp() public {
        uint8[] memory numbers = new uint8[](1);
        uint256 betAmount = 10 ether;
        
        // Place bets on all numbers
        for (uint8 i = 0; i <= 36; i++) {
            numbers[0] = i;
            vm.prank(player1);
            roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, betAmount);
        }

        uint256 balanceBefore = token.balanceOf(player1);

        vm.prank(owner);
        roulette.spin();

        uint256 balanceAfter = token.balanceOf(player1);
        
        // One bet wins: betAmount + (betAmount * 35)
        uint256 expectedPayout = betAmount + (betAmount * 35);
        assertEq(balanceAfter, balanceBefore + expectedPayout);
    }

    function test_Payout_Red() public {
        uint8[] memory numbers = new uint8[](0);
        uint256 betAmount = 10 ether;

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.RED, numbers, betAmount);

        uint256 balanceBefore = token.balanceOf(player1);

        vm.prank(owner);
        roulette.spin();

        RouletteTypes.Round memory round = roulette.getRound(1);
        uint256 balanceAfter = token.balanceOf(player1);

        if (RouletteTypes.getNumberColor(round.winningNumber) == RouletteTypes.Color.RED) {
            // Won: betAmount + (betAmount * 1) = betAmount * 2
            assertEq(balanceAfter, balanceBefore + (betAmount * 2));
        } else {
            // Lost: no payout
            assertEq(balanceAfter, balanceBefore);
        }
    }

    // ============ Admin Function Tests ============

    function test_SetMinBet() public {
        uint256 newMinBet = 2 ether;
        
        vm.prank(owner);
        roulette.setMinBet(newMinBet);

        assertEq(roulette.minBet(), newMinBet);
    }

    function test_SetMinBet_RevertIf_NotOwner() public {
        vm.prank(player1);
        vm.expectRevert();
        roulette.setMinBet(2 ether);
    }

    function test_SetMaxBet() public {
        uint256 newMaxBet = 200 ether;
        
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
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        vm.prank(player1);
        vm.expectRevert();
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);
    }

    function test_Unpause() public {
        vm.startPrank(owner);
        roulette.pause();
        roulette.unpause();
        vm.stopPrank();

        // Should work now
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

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
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

        vm.prank(player2);
        roulette.placeBet(RouletteTypes.BetType.RED, new uint8[](0), MIN_BET);

        uint256[] memory betIds = roulette.getRoundBets(1);
        assertEq(betIds.length, 2);
        assertEq(betIds[0], 1);
        assertEq(betIds[1], 2);
    }

    function test_GetBet() public {
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 17;

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, 10 ether);

        RouletteTypes.Bet memory bet = roulette.getBet(1);
        assertEq(bet.player, player1);
        assertEq(bet.amount, 10 ether);
        assertEq(bet.numbers[0], 17);
    }

    function test_GetPlayerStats() public {
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, 10 ether);

        RouletteTypes.PlayerStats memory stats = roulette.getPlayerStats(player1);
        assertEq(stats.totalBets, 1);
        assertEq(stats.totalWagered, 10 ether);
    }

    function test_GetRound() public {
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

        vm.prank(owner);
        roulette.spin();

        RouletteTypes.Round memory round = roulette.getRound(1);
        assertEq(round.roundId, 1);
        assertTrue(round.completed);
        assertTrue(round.winningNumber <= 36);
    }

    // ============ Full Round Tests ============

    function test_FullRound() public {
        // Round 1: Multiple players bet
        uint8[] memory numbers1 = new uint8[](1);
        numbers1[0] = 7;
        uint8[] memory numbersRed = new uint8[](0);

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers1, 10 ether);

        vm.prank(player2);
        roulette.placeBet(RouletteTypes.BetType.RED, numbersRed, 20 ether);

        vm.prank(player3);
        roulette.placeBet(RouletteTypes.BetType.EVEN, numbersRed, 15 ether);

        // Spin
        vm.prank(owner);
        roulette.spin();

        // Verify round 1 is complete
        RouletteTypes.Round memory round1 = roulette.getRound(1);
        assertTrue(round1.completed);
        assertEq(round1.totalBets, 45 ether);

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

        vm.prank(player1);
        roulette.placeBet(RouletteTypes.BetType.BLACK, numbersRed, 5 ether);

        vm.prank(owner);
        roulette.spin();

        assertEq(roulette.currentRoundId(), 3);
    }

    function test_MultipleRounds() public {
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 5;

        for (uint256 i = 0; i < 3; i++) {
            // Place bet
            vm.prank(player1);
            roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, MIN_BET);

            // Spin
            vm.prank(owner);
            roulette.spin();

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
}
