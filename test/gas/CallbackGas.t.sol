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
    uint8 internal constant WINNING_NUMBER = 17;

    function setUp() public override {
        super.setUp();
        _lpDeposit(lp1, LP_LIQUIDITY);
    }

    function _fillRound(uint256 bets, bool winning) internal returns (uint256 requestId) {
        for (uint256 i; i < bets; ++i) {
            address player = address(uint160(0x10000 + i));
            _fundCredits(player, MIN_BET);
            _betStraight(player, winning ? WINNING_NUMBER : WINNING_NUMBER + 1, MIN_BET);
        }
        requestId = _spin();
    }

    function _measureCallback(uint256 requestId) internal returns (uint256 gasUsed) {
        uint256[] memory words = new uint256[](1);
        words[0] = WINNING_NUMBER;
        vm.prank(address(vrfCoordinator));
        uint256 gasBefore = gasleft();
        roulette.rawFulfillRandomWords(requestId, words);
        gasUsed = gasBefore - gasleft();
    }

    /// @notice A full round where every bet wins must settle within the callback gas limit
    function test_FullWinningRound_FitsCallbackGasLimit() public {
        uint256 maxBets = roulette.MAX_BETS_PER_ROUND();
        uint256 requestId = _fillRound(maxBets, true);

        uint256 snapshot = vm.snapshotState();
        uint256 gasUsed = _measureCallback(requestId);
        vm.revertToState(snapshot);
        assertLe(gasUsed, uint256(CALLBACK_GAS_LIMIT) * 90 / 100, "keep at least 10% headroom");

        // Through the mock, with the real gas limit: the round must complete
        _fulfill(requestId, WINNING_NUMBER);
        assertTrue(roulette.getRound(1).completed, "callback ran out of gas");
        assertEq(roulette.getRound(1).totalPayout, maxBets * MIN_BET * 36);
    }

    function test_LogCallbackGas() public {
        uint256[4] memory sizes = [uint256(1), 10, 25, 45];
        for (uint256 k; k < sizes.length; ++k) {
            uint256 snapshot = vm.snapshotState();
            uint256 winGas = _measureCallback(_fillRound(sizes[k], true));
            vm.revertToState(snapshot);
            uint256 loseGas = _measureCallback(_fillRound(sizes[k], false));
            vm.revertToState(snapshot);
            console.log("bets=%s allWin=%s allLose=%s", sizes[k], winGas, loseGas);
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
