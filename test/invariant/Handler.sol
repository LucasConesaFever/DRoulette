// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {Roulette} from "src/Roulette.sol";
import {RouletteVault} from "src/RouletteVault.sol";
import {RouletteTypes} from "src/libraries/RouletteTypes.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

/**
 * @title Handler
 * @notice Drives random sequences of player, LP and owner actions for the invariant suite
 */
contract Handler is Test {
    Roulette internal immutable roulette;
    RouletteVault internal immutable vault;
    MockUSDC internal immutable usdc;
    VRFCoordinatorV2_5Mock internal immutable vrfCoordinator;
    address internal immutable owner;

    address[] public players;
    address[] public lps;

    // Ghost variables
    uint256 public ghostLpDeposited;
    uint256 public ghostLpWithdrawn;
    uint256 public ghostPendingRequestId;
    uint256 public ghostSettledRounds;
    uint256 public ghostRefundedRounds;
    // Player-side flows, tracked from the handler's own inputs (independent of Roulette's bookkeeping)
    uint256 public ghostCreditsDeposited;
    uint256 public ghostCreditsWithdrawn;
    uint256 public ghostStakesPlaced;
    uint256 public ghostStakesRefunded;
    // Late VRF answers that changed a refunded round (must stay 0). A counter, not an assert, so Echidna and Medusa can check it too
    uint256 public ghostLateFulfillViolations;
    // USDC sent straight to Roulette, and swept back out by the owner
    uint256 public ghostRouletteDonated;
    uint256 public ghostRouletteSwept;

    constructor(
        Roulette _roulette,
        RouletteVault _vault,
        MockUSDC _usdc,
        VRFCoordinatorV2_5Mock _vrfCoordinator,
        address _owner
    ) {
        roulette = _roulette;
        vault = _vault;
        usdc = _usdc;
        vrfCoordinator = _vrfCoordinator;
        owner = _owner;
        for (uint256 i; i < 4; ++i) {
            players.push(makeAddr(string.concat("player", vm.toString(i))));
            lps.push(makeAddr(string.concat("lp", vm.toString(i))));
        }
    }

    /*//////////////////////////////////////////////////////////////
                                PLAYERS
    //////////////////////////////////////////////////////////////*/
    function depositCredits(uint256 actorSeed, uint256 amount) external {
        address player = players[actorSeed % players.length];
        amount = bound(amount, 1, 10_000e6);
        usdc.mint(player, amount);
        vm.startPrank(player);
        usdc.approve(address(roulette), amount);
        roulette.depositCredits(amount);
        vm.stopPrank();
        ghostCreditsDeposited += amount;
    }

    function withdrawCredits(uint256 actorSeed, uint256 amount) external {
        address player = players[actorSeed % players.length];
        uint256 available = roulette.credits(player);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(player);
        roulette.withdrawCredits(amount);
        ghostCreditsWithdrawn += amount;
    }

    function placeBet(uint256 actorSeed, uint256 betTypeSeed, uint256 numberSeed, uint256 amount) external {
        if (roulette.state() != RouletteTypes.RouletteState.OPEN || roulette.paused()) return;
        RouletteTypes.Round memory round = roulette.getRound(roulette.currentRoundId());
        if (round.firstBetId != 0 && round.lastBetId - round.firstBetId + 1 >= roulette.MAX_BETS_PER_ROUND()) return;

        address player = players[actorSeed % players.length];
        uint256 maxAmount = roulette.credits(player);
        if (maxAmount > roulette.maxBet()) maxAmount = roulette.maxBet();
        if (maxAmount < roulette.minBet()) return;
        amount = bound(amount, roulette.minBet(), maxAmount);

        (RouletteTypes.BetType betType, uint8[] memory numbers) = _randomBet(betTypeSeed, numberSeed);

        // Skip bets the exposure limit would reject
        uint256 multiplier = RouletteTypes.getPayoutMultiplier(betType);
        uint256 netExposure = round.maxExposure + amount * (multiplier + 1) - (round.totalBets + amount);
        if (netExposure * 10_000 > vault.totalAssets() * roulette.maxExposureBps()) return;

        vm.prank(player);
        roulette.placeBet(betType, numbers, amount);
        ghostStakesPlaced += amount;
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/
    function spin() external {
        if (roulette.state() != RouletteTypes.RouletteState.OPEN || roulette.paused()) return;
        uint256 roundId = roulette.currentRoundId();
        if (roulette.getRound(roundId).firstBetId == 0) return;

        vm.warp(block.timestamp + roulette.spinDelay() + 1);
        vm.prank(owner);
        roulette.spin();
        ghostPendingRequestId = roulette.getRound(roundId).requestId;
    }

    function fulfill(uint256 word) external {
        if (ghostPendingRequestId == 0) return;
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vrfCoordinator.fulfillRandomWordsWithOverride(ghostPendingRequestId, address(roulette), words);
        ghostPendingRequestId = 0;
        ++ghostSettledRounds;
    }

    /// @dev VRF never answered: refund after the timeout, then a late answer must change nothing
    function refundAndLateFulfill(uint256 word) external {
        if (ghostPendingRequestId == 0) return;
        uint256 roundId = roulette.currentRoundId();
        uint256 stakes = roulette.getRound(roundId).totalBets;

        vm.warp(block.timestamp + roulette.vrfTimeout());
        vm.prank(owner);
        roulette.refundRound();
        ghostStakesRefunded += stakes;
        ++ghostRefundedRounds;

        uint256 creditsBefore = roulette.totalCredits();
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        // The mock swallows the callback revert; the refunded round must stay unsettled
        vrfCoordinator.fulfillRandomWordsWithOverride(ghostPendingRequestId, address(roulette), words);
        ghostPendingRequestId = 0;
        RouletteTypes.Round memory round = roulette.getRound(roundId);
        if (roulette.totalCredits() != creditsBefore || !round.refunded || round.winningNumber != 255) {
            ++ghostLateFulfillViolations;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/
    function setBetLimits(uint256 minSeed, uint256 maxSeed) external {
        uint256 newMin = bound(minSeed, 1, 10e6);
        uint256 newMax = bound(maxSeed, newMin, 1_000e6);
        vm.startPrank(owner);
        // Order the two calls so minBet <= maxBet holds after each one
        if (newMin > roulette.maxBet()) {
            roulette.setMaxBet(newMax);
            roulette.setMinBet(newMin);
        } else {
            roulette.setMinBet(newMin);
            roulette.setMaxBet(newMax);
        }
        vm.stopPrank();
    }

    function setMaxExposureBps(uint256 bps) external {
        vm.prank(owner);
        roulette.setMaxExposureBps(bound(bps, 0, 10_000));
    }

    function setSpinDelay(uint256 delay) external {
        vm.prank(owner);
        roulette.setSpinDelay(bound(delay, 0, 1 hours));
    }

    function togglePause() external {
        bool paused = roulette.paused();
        vm.prank(owner);
        if (paused) roulette.unpause();
        else roulette.pause();
    }

    function emergencyStop() external {
        if (roulette.state() != RouletteTypes.RouletteState.OPEN) return;
        vm.prank(owner);
        roulette.emergencyStopBetting();
    }

    function emergencyResume() external {
        if (roulette.state() != RouletteTypes.RouletteState.CALCULATING || ghostPendingRequestId != 0) return;
        vm.prank(owner);
        roulette.emergencyResumeBetting();
    }

    /// @dev After an emergency stop anyone can refund once the timeout passed
    function refundStoppedRound(uint256 actorSeed) external {
        if (roulette.state() != RouletteTypes.RouletteState.CALCULATING || ghostPendingRequestId != 0) return;
        uint256 stakes = roulette.getRound(roulette.currentRoundId()).totalBets;
        vm.warp(block.timestamp + roulette.vrfTimeout());
        vm.prank(players[actorSeed % players.length]);
        roulette.refundRound();
        ghostStakesRefunded += stakes;
        ++ghostRefundedRounds;
    }

    function setMaxCapacity(uint256 capacity) external {
        vm.prank(owner);
        vault.setMaxCapacity(bound(capacity, 0, 20_000_000e6));
    }

    function donateToRoulette(uint256 amount) external {
        amount = bound(amount, 1, 1_000e6);
        usdc.mint(address(roulette), amount);
        ghostRouletteDonated += amount;
    }

    function sweepExcess() external {
        uint256 excess = roulette.excessUsdc();
        if (excess == 0) return;
        vm.prank(owner);
        roulette.sweepExcess(owner);
        ghostRouletteSwept += excess;
    }

    /*//////////////////////////////////////////////////////////////
                                  LPS
    //////////////////////////////////////////////////////////////*/
    function lpDeposit(uint256 actorSeed, uint256 amount) external {
        address lp = lps[actorSeed % lps.length];
        uint256 maxAmount = vault.maxDeposit(lp);
        if (maxAmount == 0) return;
        amount = bound(amount, 1e6, 1_000_000e6);
        if (amount > maxAmount) amount = maxAmount;

        usdc.mint(lp, amount);
        vm.startPrank(lp);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, lp);
        vm.stopPrank();
        ghostLpDeposited += amount;
    }

    function lpRedeem(uint256 actorSeed, uint256 shares) external {
        address lp = lps[actorSeed % lps.length];
        uint256 maxShares = vault.maxRedeem(lp);
        if (maxShares == 0) return;
        shares = bound(shares, 1, maxShares);
        vm.prank(lp);
        ghostLpWithdrawn += vault.redeem(shares, lp, lp);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    function playersLength() external view returns (uint256) {
        return players.length;
    }

    function _randomBet(uint256 betTypeSeed, uint256 numberSeed)
        internal
        pure
        returns (RouletteTypes.BetType betType, uint8[] memory numbers)
    {
        betType = RouletteTypes.BetType(betTypeSeed % 13);
        uint8 n = uint8(numberSeed % 37);
        if (betType == RouletteTypes.BetType.STRAIGHT_UP) {
            numbers = new uint8[](1);
            numbers[0] = n;
        } else if (betType == RouletteTypes.BetType.SPLIT) {
            numbers = new uint8[](2);
            numbers[0] = n % 33 + 1;
            numbers[1] = numbers[0] + 3;
        } else if (betType == RouletteTypes.BetType.STREET) {
            numbers = new uint8[](3);
            uint8 first = uint8((numberSeed % 12) * 3 + 1);
            (numbers[0], numbers[1], numbers[2]) = (first, first + 1, first + 2);
        } else if (betType == RouletteTypes.BetType.CORNER) {
            numbers = new uint8[](4);
            uint8 first = uint8((numberSeed % 11) * 3 + 1);
            (numbers[0], numbers[1], numbers[2], numbers[3]) = (first, first + 1, first + 3, first + 4);
        } else if (betType == RouletteTypes.BetType.LINE) {
            numbers = new uint8[](6);
            uint8 first = uint8((numberSeed % 11) * 3 + 1);
            for (uint8 i; i < 6; ++i) {
                numbers[i] = first + i;
            }
        } else if (betType == RouletteTypes.BetType.DOZEN || betType == RouletteTypes.BetType.COLUMN) {
            numbers = new uint8[](1);
            numbers[0] = uint8(numberSeed % 3) + 1;
        }
    }
}
