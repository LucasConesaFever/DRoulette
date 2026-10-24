// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {RouletteTypes} from "src/libraries/RouletteTypes.sol";
import {BaseTest} from "test/utils/BaseTest.sol";
import {Handler} from "test/invariant/Handler.sol";

/**
 * @title RouletteInvariantTest
 * @notice Core protocol properties under random sequences of player, LP and owner actions
 */
contract RouletteInvariantTest is StdInvariant, BaseTest {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(roulette, vault, usdc, vrfCoordinator, owner);
        targetContract(address(handler));
    }

    /// @notice Roulette's USDC is exactly the credits plus the stakes of the round in progress
    function invariant_RouletteBalanceBacksCreditsAndStakes() public view {
        RouletteTypes.Round memory round = roulette.getRound(roulette.currentRoundId());
        uint256 openStakes = round.completed ? 0 : round.totalBets;
        assertEq(usdc.balanceOf(address(roulette)), roulette.totalCredits() + openStakes);
    }

    /// @notice The exposure limit and LP reserve make a deficit unreachable through normal use
    function invariant_NoDeficit() public view {
        assertEq(roulette.deficit(), 0);
        assertTrue(roulette.state() != RouletteTypes.RouletteState.DEFICIT);
    }

    /// @notice The vault balance changes only through LP flows and round settlement
    function invariant_VaultBalanceIsLpFlowsPlusHousePnl() public view {
        int256 expected =
            int256(handler.ghostLpDeposited()) - int256(handler.ghostLpWithdrawn()) + roulette.houseNetPnl();
        assertEq(int256(usdc.balanceOf(address(vault))), expected);
        assertEq(vault.totalAssets(), usdc.balanceOf(address(vault)));
    }

    /// @notice The vault can always pay the open round's worst case
    function invariant_VaultCoversReservedLiquidity() public view {
        assertGe(vault.totalAssets(), roulette.reservedLiquidity());
    }

    /// @notice The credit ledger total matches the per-player balances
    function invariant_TotalCreditsIsSumOfBalances() public view {
        uint256 sum;
        for (uint256 i; i < handler.playersLength(); ++i) {
            sum += roulette.credits(handler.players(i));
        }
        assertEq(roulette.totalCredits(), sum);
    }

    /// @notice House stats are consistent with each other
    function invariant_HouseStatsConsistent() public view {
        (uint256 wagered, uint256 paidOut, int256 netPnl) = roulette.getHouseStats();
        assertEq(netPnl, int256(wagered) - int256(paidOut));
    }
}
