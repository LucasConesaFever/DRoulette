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
    }

    function withdrawCredits(uint256 actorSeed, uint256 amount) external {
        address player = players[actorSeed % players.length];
        uint256 available = roulette.credits(player);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(player);
        roulette.withdrawCredits(amount);
    }

    function placeBet(uint256 actorSeed, uint256 betTypeSeed, uint256 numberSeed, uint256 amount) external {
        if (roulette.state() != RouletteTypes.RouletteState.OPEN) return;
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
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/
    function spin() external {
        if (roulette.state() != RouletteTypes.RouletteState.OPEN) return;
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
            numbers[0] = n % 36 + 1;
            numbers[1] = numbers[0] == 36 ? 35 : numbers[0] + 1;
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
