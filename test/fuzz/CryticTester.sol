// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {Roulette} from "src/Roulette.sol";
import {RouletteVault} from "src/RouletteVault.sol";
import {RouletteTypes} from "src/libraries/RouletteTypes.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";
import {Handler} from "test/invariant/Handler.sol";

/**
 * @title CryticTester
 * @notice Echidna / Medusa entry point: same Handler and properties as test/invariant/RouletteInvariant.t.sol
 * @dev Deploys in the constructor (fuzzers have no setUp). This contract is the owner of every deployed contract.
 *      Properties are `property_*` functions returning bool; keep them in sync with the Foundry invariants.
 *      echidna . --contract CryticTester --config echidna.yaml
 *      medusa fuzz
 */
contract CryticTester {
    uint256 internal constant MIN_BET = 1e6;
    uint256 internal constant MAX_BET = 100e6;
    uint256 internal constant HOUSE_EDGE = 270;
    uint256 internal constant SPIN_DELAY = 60;
    uint256 internal constant MAX_EXPOSURE_BPS = 1_000;
    uint256 internal constant VRF_TIMEOUT = 1 hours;
    uint256 internal constant MAX_VAULT_CAPACITY = 10_000_000e6;
    uint32 internal constant CALLBACK_GAS_LIMIT = 2_500_000;
    bytes32 internal constant GAS_LANE = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;

    Roulette internal immutable roulette;
    RouletteVault internal immutable vault;
    MockUSDC internal immutable usdc;
    Handler internal immutable handler;

    constructor() {
        VRFCoordinatorV2_5Mock vrfCoordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 4e15);
        uint256 subscriptionId = vrfCoordinator.createSubscription();
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

        handler = new Handler(roulette, vault, usdc, vrfCoordinator, address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                 ACTIONS
    //////////////////////////////////////////////////////////////*/
    function depositCredits(uint256 actorSeed, uint256 amount) external {
        handler.depositCredits(actorSeed, amount);
    }

    function withdrawCredits(uint256 actorSeed, uint256 amount) external {
        handler.withdrawCredits(actorSeed, amount);
    }

    function placeBet(uint256 actorSeed, uint256 betTypeSeed, uint256 numberSeed, uint256 amount) external {
        handler.placeBet(actorSeed, betTypeSeed, numberSeed, amount);
    }

    function spin() external {
        handler.spin();
    }

    function fulfill(uint256 word) external {
        handler.fulfill(word);
    }

    function refundAndLateFulfill(uint256 word) external {
        handler.refundAndLateFulfill(word);
    }

    function lpDeposit(uint256 actorSeed, uint256 amount) external {
        handler.lpDeposit(actorSeed, amount);
    }

    function lpRedeem(uint256 actorSeed, uint256 shares) external {
        handler.lpRedeem(actorSeed, shares);
    }

    /*//////////////////////////////////////////////////////////////
                               PROPERTIES
    //////////////////////////////////////////////////////////////*/
    function property_RouletteBalanceBacksCreditsAndStakes() external view returns (bool) {
        return usdc.balanceOf(address(roulette)) == roulette.totalCredits() + _openStakes();
    }

    function property_NoDeficit() external view returns (bool) {
        return roulette.deficit() == 0 && roulette.state() != RouletteTypes.RouletteState.DEFICIT;
    }

    function property_VaultBalanceIsLpFlowsPlusHousePnl() external view returns (bool) {
        int256 expected =
            int256(handler.ghostLpDeposited()) - int256(handler.ghostLpWithdrawn()) + roulette.houseNetPnl();
        uint256 balance = usdc.balanceOf(address(vault));
        return int256(balance) == expected && vault.totalAssets() == balance;
    }

    function property_VaultCoversReservedLiquidity() external view returns (bool) {
        return vault.totalAssets() >= roulette.reservedLiquidity();
    }

    function property_TotalCreditsIsSumOfBalances() external view returns (bool) {
        uint256 sum;
        for (uint256 i; i < handler.playersLength(); ++i) {
            sum += roulette.credits(handler.players(i));
        }
        return roulette.totalCredits() == sum;
    }

    function property_CreditsConservation() external view returns (bool) {
        (, uint256 paidOut,) = roulette.getHouseStats();
        return roulette.totalCredits()
            == handler.ghostCreditsDeposited() + handler.ghostStakesRefunded() + paidOut
                - handler.ghostCreditsWithdrawn() - handler.ghostStakesPlaced();
    }

    function property_HouseWageredIsSettledStakes() external view returns (bool) {
        (uint256 wagered,,) = roulette.getHouseStats();
        return wagered == handler.ghostStakesPlaced() - handler.ghostStakesRefunded() - _openStakes();
    }

    function property_LateFulfillIsIgnored() external view returns (bool) {
        return handler.ghostLateFulfillViolations() == 0;
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    function _openStakes() internal view returns (uint256) {
        RouletteTypes.Round memory round = roulette.getRound(roulette.currentRoundId());
        return round.completed ? 0 : round.totalBets;
    }
}
