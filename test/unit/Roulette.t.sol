// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Roulette} from "src/Roulette.sol";
import {RouletteTypes} from "src/libraries/RouletteTypes.sol";
import {BaseTest} from "test/utils/BaseTest.sol";

contract RouletteTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _lpDeposit(lp1, LP_LIQUIDITY);
    }

    /*//////////////////////////////////////////////////////////////
                                CREDITS
    //////////////////////////////////////////////////////////////*/
    function testFuzz_DepositCredits_HeldByRoulette(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        _fundCredits(player1, amount);

        assertEq(roulette.credits(player1), amount);
        assertEq(roulette.totalCredits(), amount);
        assertEq(usdc.balanceOf(address(roulette)), amount);
        assertEq(usdc.balanceOf(address(vault)), vaultBefore, "vault must not receive player funds");
    }

    function test_DepositCredits_RevertWhen_Zero() public {
        vm.prank(player1);
        vm.expectRevert(Roulette.Roulette__InvalidAmount.selector);
        roulette.depositCredits(0);
    }

    function testFuzz_WithdrawCredits(uint256 deposited, uint256 withdrawn) public {
        deposited = bound(deposited, 1, 1e30);
        withdrawn = bound(withdrawn, 1, deposited);
        _fundCredits(player1, deposited);

        vm.prank(player1);
        roulette.withdrawCredits(withdrawn);

        assertEq(roulette.credits(player1), deposited - withdrawn);
        assertEq(roulette.totalCredits(), deposited - withdrawn);
        assertEq(usdc.balanceOf(player1), withdrawn);
        assertEq(usdc.balanceOf(address(roulette)), deposited - withdrawn);
    }

    function testFuzz_WithdrawCredits_RevertWhen_MoreThanBalance(uint256 deposited, uint256 extra) public {
        deposited = bound(deposited, 1, 1e30);
        extra = bound(extra, 1, 1e30);
        _fundCredits(player1, deposited);

        vm.prank(player1);
        vm.expectRevert(Roulette.Roulette__InsufficientCredits.selector);
        roulette.withdrawCredits(deposited + extra);
    }

    function test_WithdrawCredits_RevertWhen_Zero() public {
        vm.prank(player1);
        vm.expectRevert(Roulette.Roulette__InvalidAmount.selector);
        roulette.withdrawCredits(0);
    }

    function test_WithdrawCredits_AllowedWhileCalculating() public {
        _fundCredits(player1, 50e6);
        _betRed(player1, 10e6);
        _spin();

        vm.prank(player1);
        roulette.withdrawCredits(40e6);

        assertEq(usdc.balanceOf(player1), 40e6);
        _assertRouletteSolvent();
    }

    /*//////////////////////////////////////////////////////////////
                                PLACE BET
    //////////////////////////////////////////////////////////////*/
    function testFuzz_PlaceBet_DebitsCreditsAndStoresBet(uint256 amount, uint8 number) public {
        amount = bound(amount, MIN_BET, MAX_BET);
        number = uint8(bound(number, 0, 36));
        _fundCredits(player1, MAX_BET);

        _betStraight(player1, number, amount);

        assertEq(roulette.credits(player1), MAX_BET - amount);
        assertEq(roulette.totalCredits(), MAX_BET - amount);
        assertEq(usdc.balanceOf(address(roulette)), MAX_BET, "stake stays in roulette");

        RouletteTypes.Bet memory bet = roulette.getBet(1);
        assertEq(bet.player, player1);
        assertEq(uint8(bet.betType), uint8(RouletteTypes.BetType.STRAIGHT_UP));
        assertEq(bet.numbersMask, uint40(1) << number);
        assertEq(bet.amount, amount);

        RouletteTypes.Round memory round = roulette.getRound(1);
        assertEq(round.firstBetId, 1);
        assertEq(round.lastBetId, 1);
        assertEq(round.totalBets, amount);
        assertEq(round.maxExposure, amount * 36);
        assertEq(roulette.reservedLiquidity(), amount * 35);
        _assertRouletteSolvent();
    }

    function test_PlaceBet_ContiguousBetIdsPerRound() public {
        _fundCredits(player1, 100e6);
        _fundCredits(player2, 100e6);
        _betRed(player1, 1e6);
        _betBlack(player2, 1e6);
        _betRed(player1, 1e6);

        uint256[] memory betIds = roulette.getRoundBets(1);
        assertEq(betIds.length, 3);
        assertEq(betIds[0], 1);
        assertEq(betIds[2], 3);

        _spinAndFulfill(RED_NUMBER);
        _betRed(player1, 1e6);
        assertEq(roulette.getRound(2).firstBetId, 4);
    }

    function test_PlaceBet_RevertWhen_InvalidNumbers() public {
        _fundCredits(player1, 10e6);
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 37;
        vm.prank(player1);
        vm.expectRevert(Roulette.Roulette__InvalidNumbers.selector);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, 1e6);
    }

    function test_PlaceBet_RevertWhen_CornerNumberAbove36() public {
        _fundCredits(player1, 10e6);
        uint8[] memory numbers = new uint8[](4);
        numbers[0] = 1;
        numbers[1] = 2;
        numbers[2] = 4;
        numbers[3] = 40;
        vm.prank(player1);
        vm.expectRevert(abi.encodeWithSelector(RouletteTypes.RouletteTypes__NumberOutOfRange.selector, 40));
        roulette.placeBet(RouletteTypes.BetType.CORNER, numbers, 1e6);
    }

    function testFuzz_PlaceBet_RevertWhen_AmountOutOfRange(uint256 amount) public {
        vm.assume(amount < MIN_BET || amount > MAX_BET);
        _fundCredits(player1, MAX_BET);
        vm.prank(player1);
        vm.expectRevert(Roulette.Roulette__InvalidBetAmount.selector);
        roulette.placeBet(RouletteTypes.BetType.RED, new uint8[](0), amount);
    }

    function test_PlaceBet_RevertWhen_InsufficientCredits() public {
        _fundCredits(player1, 5e6);
        vm.prank(player1);
        vm.expectRevert(Roulette.Roulette__InsufficientCredits.selector);
        roulette.placeBet(RouletteTypes.BetType.RED, new uint8[](0), 6e6);
    }

    function test_PlaceBet_RevertWhen_Calculating() public {
        _fundCredits(player1, 10e6);
        _betRed(player1, 1e6);
        _spin();

        vm.prank(player1);
        vm.expectRevert(Roulette.Roulette__RouletteNotOpen.selector);
        roulette.placeBet(RouletteTypes.BetType.RED, new uint8[](0), 1e6);
    }

    function test_PlaceBet_RevertWhen_Paused() public {
        _fundCredits(player1, 10e6);
        vm.prank(owner);
        roulette.pause();

        vm.prank(player1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        roulette.placeBet(RouletteTypes.BetType.RED, new uint8[](0), 1e6);
    }

    function test_PlaceBet_RevertWhen_ExposureLimitExceeded() public {
        // 10% of 100k = 10k of net worst case. Straight up 100 USDC = 3,500 net each.
        _fundCredits(player1, 1_000e6);
        _betStraight(player1, 7, 100e6);
        _betStraight(player1, 8, 100e6);

        vm.prank(player1);
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 9;
        vm.expectRevert(Roulette.Roulette__ExposureLimitExceeded.selector);
        roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, 100e6);
    }

    function test_PlaceBet_RevertWhen_VaultEmpty() public {
        uint256 shares = vault.balanceOf(lp1);
        vm.prank(lp1);
        vault.redeem(shares, lp1, lp1);
        _fundCredits(player1, 10e6);

        vm.prank(player1);
        vm.expectRevert(Roulette.Roulette__ExposureLimitExceeded.selector);
        roulette.placeBet(RouletteTypes.BetType.RED, new uint8[](0), 1e6);
    }

    function test_PlaceBet_ExposureLimitFollowsOwnerSetting() public {
        vm.prank(owner);
        roulette.setMaxExposureBps(3_500); // 35% = 35k net
        _fundCredits(player1, 1_000e6);
        for (uint8 i = 1; i <= 10; ++i) {
            _betStraight(player1, i, 100e6);
        }
        assertEq(roulette.reservedLiquidity(), 35_000e6);
    }

    function test_PlaceBet_RevertWhen_RoundFull() public {
        uint256 maxBets = roulette.MAX_BETS_PER_ROUND();
        _fundCredits(player1, maxBets * MIN_BET + MIN_BET);
        for (uint256 i; i < maxBets; ++i) {
            _betRed(player1, MIN_BET);
        }

        vm.prank(player1);
        vm.expectRevert(Roulette.Roulette__RoundFull.selector);
        roulette.placeBet(RouletteTypes.BetType.RED, new uint8[](0), MIN_BET);
    }

    /*//////////////////////////////////////////////////////////////
                                  SPIN
    //////////////////////////////////////////////////////////////*/
    function test_Spin_LocksLps() public {
        _fundCredits(player1, 10e6);
        _betRed(player1, 1e6);
        assertFalse(roulette.lpLocked());

        _spin();

        assertEq(uint8(roulette.state()), uint8(RouletteTypes.RouletteState.CALCULATING));
        assertTrue(roulette.lpLocked());
        assertTrue(vault.isLpLocked());
        assertEq(roulette.spinRequestedAt(), block.timestamp);
    }

    function test_Spin_RevertWhen_NoBets() public {
        vm.prank(owner);
        vm.expectRevert(Roulette.Roulette__NoActiveBets.selector);
        roulette.spin();
    }

    function test_Spin_RevertWhen_NotOwner() public {
        _fundCredits(player1, 10e6);
        _betRed(player1, 1e6);
        vm.prank(player1);
        vm.expectRevert("Only callable by owner");
        roulette.spin();
    }

    function test_Spin_RevertWhen_SpinDelayNotMet() public {
        _fundCredits(player1, 10e6);
        _betRed(player1, 1e6);
        _spinAndFulfill(RED_NUMBER);
        _betRed(player1, 1e6);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Roulette.Roulette__SpinDelayNotMet.selector, SPIN_DELAY));
        roulette.spin();
    }

    function test_Spin_RevertWhen_AlreadyCalculating() public {
        _fundCredits(player1, 10e6);
        _betRed(player1, 1e6);
        _spin();
        vm.prank(owner);
        vm.expectRevert(Roulette.Roulette__AlreadyCalculating.selector);
        roulette.spin();
    }

    /*//////////////////////////////////////////////////////////////
                               SETTLEMENT
    //////////////////////////////////////////////////////////////*/
    function test_Settle_PlayerLoses_StakeGoesToVault() public {
        _fundCredits(player1, 10e6);
        _betRed(player1, 10e6);
        uint256 vaultBefore = vault.totalAssets();

        uint256 roundId = _spinAndFulfill(BLACK_NUMBER);

        assertEq(vault.totalAssets(), vaultBefore + 10e6);
        assertEq(roulette.credits(player1), 0);
        assertEq(usdc.balanceOf(address(roulette)), 0);
        assertTrue(roulette.getRound(roundId).completed);
        assertEq(uint8(roulette.state()), uint8(RouletteTypes.RouletteState.OPEN));
        assertFalse(roulette.lpLocked());
        assertEq(roulette.currentRoundId(), roundId + 1);
    }

    function test_Settle_PlayerWins_NetPulledFromVault() public {
        _fundCredits(player1, 10e6);
        _betStraight(player1, 17, 10e6);
        uint256 vaultBefore = vault.totalAssets();

        _spinAndFulfill(17);

        assertEq(roulette.credits(player1), 360e6);
        assertEq(vault.totalAssets(), vaultBefore - 350e6);
        assertEq(usdc.balanceOf(address(roulette)), 360e6);
        _assertRouletteSolvent();
    }

    function test_Settle_MixedRound_OneNetTransfer() public {
        _fundCredits(player1, 10e6);
        _fundCredits(player2, 10e6);
        _betRed(player1, 10e6);
        _betBlack(player2, 10e6);
        uint256 vaultBefore = vault.totalAssets();

        _spinAndFulfill(RED_NUMBER);

        // player1 gets 20, player2 loses 10: net to players 0
        assertEq(roulette.credits(player1), 20e6);
        assertEq(roulette.credits(player2), 0);
        assertEq(vault.totalAssets(), vaultBefore);
    }

    function test_Settle_ZeroTakesOutsideBets() public {
        _fundCredits(player1, 10e6);
        _fundCredits(player2, 10e6);
        _betRed(player1, 10e6);
        _betBlack(player2, 10e6);
        uint256 vaultBefore = vault.totalAssets();

        _spinAndFulfill(ZERO);

        assertEq(roulette.totalCredits(), 0);
        assertEq(vault.totalAssets(), vaultBefore + 20e6);
    }

    function testFuzz_Settle_NetTransferMatchesPayouts(uint256 word, uint256[3] memory amounts, uint8 number)
        public
    {
        number = uint8(bound(number, 0, 36));
        for (uint256 i; i < 3; ++i) {
            amounts[i] = bound(amounts[i], MIN_BET, MAX_BET);
        }
        _fundCredits(player1, amounts[0]);
        _fundCredits(player2, amounts[1]);
        _fundCredits(player3, amounts[2]);
        _betRed(player1, amounts[0]);
        _betStraight(player2, number, amounts[1]);
        uint8[] memory dozen = new uint8[](1);
        dozen[0] = 2;
        _bet(player3, RouletteTypes.BetType.DOZEN, dozen, amounts[2]);

        uint256 vaultBefore = vault.totalAssets();
        uint256 totalBets = amounts[0] + amounts[1] + amounts[2];
        uint256 roundId = _spinAndFulfill(word);

        RouletteTypes.Round memory round = roulette.getRound(roundId);
        assertTrue(round.completed);
        assertEq(round.totalPayout, roulette.totalCredits(), "all payouts credited");
        assertEq(vault.totalAssets() + round.totalPayout, vaultBefore + totalBets, "one net transfer");
        _assertRouletteSolvent();

        (uint256 wagered, uint256 paidOut, int256 netPnl) = roulette.getHouseStats();
        assertEq(wagered, totalBets);
        assertEq(paidOut, round.totalPayout);
        assertEq(netPnl, int256(totalBets) - int256(uint256(round.totalPayout)));
    }

    function test_Settle_PlayerStats() public {
        _fundCredits(player1, 100e6);
        _betRed(player1, 10e6);
        _betBlack(player1, 5e6);
        _betStraight(player1, 1, 2e6);

        RouletteTypes.PlayerStatsView memory pending = roulette.getPlayerStats(player1);
        assertEq(pending.totalBets, 3);
        assertEq(pending.totalWagered, 17e6);
        assertEq(pending.totalLost, 0, "open round stakes are not losses yet");

        _spinAndFulfill(RED_NUMBER); // 1 is red: red and straight up win, black loses

        RouletteTypes.PlayerStatsView memory stats = roulette.getPlayerStats(player1);
        assertEq(stats.totalWagered, 17e6);
        assertEq(stats.totalWon, 10e6 + 70e6);
        assertEq(stats.totalLost, 5e6);
        assertEq(stats.lastPlayedTimestamp, roulette.getRound(1).timestamp);
    }

    function test_GetBetResult() public {
        _fundCredits(player1, 100e6);
        _betRed(player1, 10e6);
        _betBlack(player1, 10e6);

        (bool settled,,) = roulette.getBetResult(1, 1);
        assertFalse(settled);

        _spinAndFulfill(RED_NUMBER);

        (bool settled1, bool won1, uint256 payout1) = roulette.getBetResult(1, 1);
        (bool settled2, bool won2, uint256 payout2) = roulette.getBetResult(2, 1);
        assertTrue(settled1 && won1);
        assertEq(payout1, 20e6);
        assertTrue(settled2 && !won2);
        assertEq(payout2, 0);

        (bool wrongRound,,) = roulette.getBetResult(1, 2);
        assertFalse(wrongRound);
    }

    function test_Fulfill_RevertWhen_UnknownRequest() public {
        uint256[] memory words = new uint256[](1);
        vm.prank(address(vrfCoordinator));
        vm.expectRevert(Roulette.Roulette__InvalidRequestId.selector);
        roulette.rawFulfillRandomWords(12345, words);
    }

    /// @dev The owner can call the inherited setCoordinator, but that must not let them pick numbers
    function test_Fulfill_OwnerSetCoordinatorCannotPickNumbers() public {
        _fundCredits(player1, 10e6);
        _betStraight(player1, 17, 10e6);
        uint256 requestId = _spin();

        vm.prank(owner);
        roulette.setCoordinator(owner);

        uint256[] memory words = new uint256[](1);
        words[0] = 17;
        vm.prank(owner);
        vm.expectRevert(Roulette.Roulette__OnlyVrfCoordinator.selector);
        roulette.rawFulfillRandomWords(requestId, words);

        (address coordinator,,,,) = roulette.getVrfConfig();
        assertEq(coordinator, address(vrfCoordinator));
    }

    function test_Fulfill_RevertWhen_AlreadyFulfilled() public {
        _fundCredits(player1, 10e6);
        _betRed(player1, 1e6);
        uint256 requestId = _spin();
        _fulfill(requestId, RED_NUMBER);

        uint256[] memory words = new uint256[](1);
        vm.prank(address(vrfCoordinator));
        vm.expectRevert(Roulette.Roulette__InvalidRequestId.selector);
        roulette.rawFulfillRandomWords(requestId, words);
    }

    /*//////////////////////////////////////////////////////////////
                             LP PROTECTION
    //////////////////////////////////////////////////////////////*/
    function test_Lp_WithdrawCappedByReservedLiquidity() public {
        // Raise the limit so the reserve is large enough to bind on the only LP
        vm.prank(owner);
        roulette.setMaxExposureBps(10_000);
        _fundCredits(player1, 1_000e6);
        for (uint8 i = 1; i <= 10; ++i) {
            _betStraight(player1, i, 100e6);
        }
        uint256 reserved = roulette.reservedLiquidity();
        assertEq(reserved, 35_000e6);

        assertEq(vault.maxWithdraw(lp1), LP_LIQUIDITY - reserved);
        vm.prank(lp1);
        vm.expectRevert();
        vault.withdraw(LP_LIQUIDITY - reserved + 1, lp1, lp1);
    }

    function test_Lp_LockedWhileCalculating() public {
        _fundCredits(player1, 10e6);
        _betRed(player1, 1e6);
        _spin();

        assertEq(vault.maxDeposit(lp2), 0);
        assertEq(vault.maxWithdraw(lp1), 0);
        assertEq(vault.maxRedeem(lp1), 0);

        usdc.mint(lp2, 1e6);
        vm.startPrank(lp2);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, lp2, 1e6, 0));
        vault.deposit(1e6, lp2);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                DEFICIT
    //////////////////////////////////////////////////////////////*/
    /// @dev The safeguards make a deficit unreachable through normal use, so the vault is drained with `deal`
    function _createDeficit() internal returns (uint256 owed) {
        _fundCredits(player1, 100e6);
        _fundCredits(player2, 100e6);
        _betStraight(player1, 17, 100e6); // wins 3,500 net
        uint256 requestId = _spin();
        deal(address(usdc), address(vault), 1_000e6);

        _fulfill(requestId, 17);
        owed = 3_500e6 - 1_000e6;
    }

    function test_Deficit_RecordedWhenVaultShort() public {
        uint256 owed = _createDeficit();

        assertEq(uint8(roulette.state()), uint8(RouletteTypes.RouletteState.DEFICIT));
        assertEq(roulette.deficit(), owed);
        assertEq(roulette.credits(player1), 3_600e6, "winner credited in full");
        assertEq(usdc.balanceOf(address(vault)), 0, "vault drained to cover what it can");
        assertTrue(roulette.lpLocked());
        assertTrue(roulette.getRound(1).completed);
        _assertRouletteSolvent();
    }

    function test_Deficit_BlocksBetsAndSpins() public {
        _createDeficit();

        vm.prank(player2);
        vm.expectRevert(Roulette.Roulette__RouletteNotOpen.selector);
        roulette.placeBet(RouletteTypes.BetType.RED, new uint8[](0), 1e6);

        vm.prank(owner);
        vm.expectRevert(Roulette.Roulette__AlreadyCalculating.selector);
        roulette.spin();

        vm.startPrank(owner);
        vm.expectRevert(Roulette.Roulette__DeficitOpen.selector);
        roulette.emergencyResumeBetting();
        vm.expectRevert(Roulette.Roulette__DeficitOpen.selector);
        roulette.emergencyStopBetting();
        vm.stopPrank();
    }

    function test_Deficit_WithdrawalsFirstComeFirstServed() public {
        _createDeficit();
        // Roulette holds 100 (player2) + 1,100 (player1 stake + pulled) = 1,200 for 3,700 of credits
        uint256 balance = usdc.balanceOf(address(roulette));
        assertEq(balance, 1_200e6);

        vm.prank(player2);
        roulette.withdrawCredits(100e6);
        vm.prank(player1);
        roulette.withdrawCredits(1_100e6);

        vm.prank(player1);
        vm.expectRevert(Roulette.Roulette__InsufficientRouletteBalance.selector);
        roulette.withdrawCredits(1);
        _assertRouletteSolvent();
    }

    function test_Deficit_CoverPartiallyThenFully() public {
        uint256 owed = _createDeficit();

        usdc.mint(address(vault), 1_000e6);
        roulette.coverDeficit();
        assertEq(roulette.deficit(), owed - 1_000e6);
        assertEq(uint8(roulette.state()), uint8(RouletteTypes.RouletteState.DEFICIT));

        usdc.mint(address(vault), owed);
        roulette.coverDeficit();
        assertEq(roulette.deficit(), 0);
        assertEq(uint8(roulette.state()), uint8(RouletteTypes.RouletteState.OPEN));
        assertFalse(roulette.lpLocked());
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "excess stays in the vault");

        vm.prank(player1);
        roulette.withdrawCredits(3_600e6);
        _assertRouletteSolvent();
    }

    function test_CoverDeficit_RevertWhen_NoDeficit() public {
        vm.expectRevert(Roulette.Roulette__NoDeficit.selector);
        roulette.coverDeficit();
    }

    function test_CoverDeficit_RevertWhen_VaultEmpty() public {
        _createDeficit();
        vm.expectRevert(Roulette.Roulette__NothingToCover.selector);
        roulette.coverDeficit();
    }

    /*//////////////////////////////////////////////////////////////
                                 REFUND
    //////////////////////////////////////////////////////////////*/
    function test_RefundRound_AfterTimeout() public {
        _fundCredits(player1, 50e6);
        _fundCredits(player2, 50e6);
        _betRed(player1, 10e6);
        _betStraight(player2, 3, 20e6);
        uint256 requestId = _spin();
        uint256 vaultBefore = vault.totalAssets();

        vm.warp(block.timestamp + VRF_TIMEOUT);
        vm.prank(owner);
        roulette.refundRound();

        assertEq(roulette.credits(player1), 50e6);
        assertEq(roulette.credits(player2), 50e6);
        assertEq(roulette.totalCredits(), 100e6);
        assertEq(vault.totalAssets(), vaultBefore);
        assertEq(uint8(roulette.state()), uint8(RouletteTypes.RouletteState.OPEN));
        assertEq(roulette.currentRoundId(), 2);
        assertTrue(roulette.getRound(1).refunded);

        RouletteTypes.PlayerStatsView memory stats = roulette.getPlayerStats(player1);
        assertEq(stats.totalBets, 0);
        assertEq(stats.totalWagered, 0);
        assertEq(stats.totalLost, 0);

        // A late VRF answer can't settle the refunded round
        uint256[] memory words = new uint256[](1);
        vm.prank(address(vrfCoordinator));
        vm.expectRevert(Roulette.Roulette__InvalidRequestId.selector);
        roulette.rawFulfillRandomWords(requestId, words);
        _assertRouletteSolvent();
    }

    function test_RefundRound_RevertWhen_TimeoutNotReached() public {
        _fundCredits(player1, 10e6);
        _betRed(player1, 1e6);
        _spin();

        vm.warp(block.timestamp + VRF_TIMEOUT - 10);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Roulette.Roulette__VrfTimeoutNotReached.selector, 10));
        roulette.refundRound();
    }

    function test_RefundRound_RevertWhen_NotCalculating() public {
        vm.prank(owner);
        vm.expectRevert(Roulette.Roulette__NotCalculating.selector);
        roulette.refundRound();
    }

    function test_RefundRound_RevertWhen_NotOwner() public {
        vm.prank(player1);
        vm.expectRevert("Only callable by owner");
        roulette.refundRound();
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN / EMERGENCY
    //////////////////////////////////////////////////////////////*/
    function test_EmergencyResume_RevertWhen_SpinPending() public {
        _fundCredits(player1, 10e6);
        _betRed(player1, 1e6);
        _spin();

        vm.prank(owner);
        vm.expectRevert(Roulette.Roulette__SpinPending.selector);
        roulette.emergencyResumeBetting();
    }

    function test_EmergencyStopAndResume() public {
        vm.startPrank(owner);
        roulette.emergencyStopBetting();
        assertTrue(roulette.lpLocked());
        roulette.emergencyResumeBetting();
        assertFalse(roulette.lpLocked());
        vm.stopPrank();
    }

    function testFuzz_SetMaxExposureBps_RevertWhen_AboveMax(uint256 bps) public {
        bps = bound(bps, 10_001, type(uint256).max);
        vm.prank(owner);
        vm.expectRevert(Roulette.Roulette__InvalidBps.selector);
        roulette.setMaxExposureBps(bps);
    }

    function test_Setters_OnlyOwner() public {
        vm.startPrank(player1);
        vm.expectRevert("Only callable by owner");
        roulette.setMaxExposureBps(1);
        vm.expectRevert("Only callable by owner");
        roulette.setVrfTimeout(1);
        vm.expectRevert("Only callable by owner");
        roulette.setMinBet(1);
        vm.expectRevert("Only callable by owner");
        roulette.setMaxBet(1);
        vm.stopPrank();
    }

    function test_Setters_UpdateValues() public {
        vm.startPrank(owner);
        roulette.setMaxExposureBps(500);
        roulette.setVrfTimeout(2 hours);
        roulette.setMinBet(2e6);
        roulette.setMaxBet(50e6);
        roulette.setSpinDelay(10);
        roulette.setHouseEdge(100);
        vm.stopPrank();

        assertEq(roulette.maxExposureBps(), 500);
        assertEq(roulette.vrfTimeout(), 2 hours);
        assertEq(roulette.minBet(), 2e6);
        assertEq(roulette.maxBet(), 50e6);
        assertEq(roulette.spinDelay(), 10);
        assertEq(roulette.houseEdge(), 100);
    }
}
