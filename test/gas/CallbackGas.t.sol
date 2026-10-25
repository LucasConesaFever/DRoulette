// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Test.sol";
import {RouletteTypes} from "src/libraries/RouletteTypes.sol";
import {BaseTest} from "test/utils/BaseTest.sol";

/**
 * @title CallbackGasTest
 * @notice Measures fulfillRandomWords gas, used to size MAX_BETS_PER_ROUND
 * @dev Worst case per winning bet: a distinct player with 0 credits left and no previous win,
 *      so the credit and stats writes are zero -> non-zero.
 */
contract CallbackGasTest is BaseTest {
    uint8 internal constant WINNING_NUMBER = 19; // high, for HIGH bets

    function setUp() public override {
        super.setUp();
        _lpDeposit(lp1, LP_LIQUIDITY);
    }

    /// @dev Fills a round with distinct players. HIGH bets are the most expensive type to settle.
    function _fillRound(uint256 bets, bool winning, bool highBets) internal returns (uint256 requestId) {
        for (uint256 i; i < bets; ++i) {
            address player = address(uint160(0x10000 + i));
            _fundCredits(player, MIN_BET);
            if (highBets) {
                _bet(player, winning ? RouletteTypes.BetType.HIGH : RouletteTypes.BetType.LOW, new uint8[](0), MIN_BET);
            } else {
                _betStraight(player, winning ? WINNING_NUMBER : WINNING_NUMBER + 1, MIN_BET);
            }
        }
        requestId = _spin();
    }

    /// @dev Gas of the callback alone, with every touched account's storage cold as on-chain
    function _measureCallback(uint256 requestId) internal returns (uint256 gasUsed) {
        uint256[] memory words = new uint256[](1);
        words[0] = WINNING_NUMBER;
        vm.cool(address(roulette));
        vm.cool(address(vault));
        vm.cool(address(usdc));
        vm.prank(address(vrfCoordinator));
        uint256 gasBefore = gasleft();
        roulette.rawFulfillRandomWords(requestId, words);
        gasUsed = gasBefore - gasleft();
    }

    /// @notice A full round where every bet wins must settle within the callback gas limit
    function test_FullWinningRound_FitsCallbackGasLimit() public {
        uint256 maxBets = roulette.MAX_BETS_PER_ROUND();
        uint256 requestId = _fillRound(maxBets, true, true);

        uint256 snapshot = vm.snapshotState();
        uint256 gasUsed = _measureCallback(requestId);
        vm.revertToState(snapshot);
        assertLe(gasUsed, uint256(CALLBACK_GAS_LIMIT) * 90 / 100, "keep at least 10% headroom");

        // Through the mock, with the real gas limit: the round must complete
        _fulfill(requestId, WINNING_NUMBER);
        assertTrue(roulette.getRound(1).completed, "callback ran out of gas");
        (, uint256 paidOut,) = roulette.getHouseStats();
        assertEq(paidOut, maxBets * MIN_BET * 2);
    }

    function test_LogCallbackGas() public {
        uint256[4] memory sizes = [uint256(1), 10, 25, 40];
        for (uint256 k; k < sizes.length; ++k) {
            uint256 snapshot = vm.snapshotState();
            uint256 winStraight = _measureCallback(_fillRound(sizes[k], true, false));
            vm.revertToState(snapshot);
            uint256 winHigh = _measureCallback(_fillRound(sizes[k], true, true));
            vm.revertToState(snapshot);
            uint256 lose = _measureCallback(_fillRound(sizes[k], false, false));
            vm.revertToState(snapshot);
            console.log("bets=%s allWinStraight=%s allWinHigh=%s", sizes[k], winStraight, winHigh);
            console.log("    allLose=%s", lose);
        }
    }

    /// @notice Placing a bet stays cheap for players: one bet slot plus round and stats updates
    function test_LogPlaceBetGas() public {
        _fundCredits(player1, 100e6);
        _fundCredits(player2, 100e6);
        _betRed(player1, 1e6); // first bet of the round pays for round setup

        vm.prank(player2);
        uint256 gasBefore = gasleft();
        roulette.placeBet(RouletteTypes.BetType.RED, new uint8[](0), 1e6);
        console.log("placeBet (second bet of round, new player)", gasBefore - gasleft());
    }
}
