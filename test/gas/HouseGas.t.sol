// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {console} from "forge-std/Test.sol";
import {RouletteTypes} from "src/libraries/RouletteTypes.sol";
import {BaseTest} from "test/utils/BaseTest.sol";

/// @dev Stands in for the coordinator: measures the callback with gasleft(), like VRF billing (refunds excluded)
contract CallbackProbe {
    function measure(address target, uint256 requestId, uint256[] calldata words) external returns (uint256 used) {
        bytes memory data = abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])", requestId, words);
        uint256 g = gasleft();
        (bool ok,) = target.call(data);
        used = g - gasleft();
        require(ok, "callback reverted");
    }
}

/**
 * @title HouseGasTest
 * @notice Logs the gas the house pays per round: spin() and the VRF callback (billed to the subscription)
 * @dev Steady state (second round), every touched account's storage cold. The callback is measured through
 *      CallbackProbe, etched at the coordinator address, so refunds are excluded as in VRF billing.
 *      forge test --isolate --match-path test/gas/HouseGas.t.sol -vv
 */
contract HouseGasTest is BaseTest {
    uint8 internal constant N = 19;

    function setUp() public override {
        super.setUp();
        _lpDeposit(lp1, LP_LIQUIDITY);
        // Warm-up round so globals are non-zero, like in steady state
        _fundCredits(player3, 10e6);
        _betRed(player3, 1e6);
        _spinAndFulfill(RED_NUMBER);
    }

    function _cold() internal {
        vm.cool(address(roulette));
        vm.cool(address(vault));
        vm.cool(address(usdc));
        vm.cool(address(vrfCoordinator));
    }

    /// @dev Fresh players (worst case); winners bet HIGH, losers LOW
    function _round(uint256 bets, uint256 winners) internal returns (uint256 spinGas, uint256 cbGas) {
        for (uint256 i; i < bets; ++i) {
            address p = address(uint160(0x10000 + i));
            _fundCredits(p, MIN_BET);
            _bet(p, i < winners ? RouletteTypes.BetType.HIGH : RouletteTypes.BetType.LOW, new uint8[](0), MIN_BET);
        }
        vm.warp(block.timestamp + SPIN_DELAY + 1);
        uint256 roundId = roulette.currentRoundId();
        _cold();
        vm.prank(owner);
        uint256 g = gasleft();
        roulette.spin();
        spinGas = g - gasleft();
        uint256 requestId = roulette.pendingRequestId();

        uint256[] memory words = new uint256[](1);
        words[0] = N;
        vm.etch(address(vrfCoordinator), type(CallbackProbe).runtimeCode);
        _cold();
        cbGas = CallbackProbe(address(vrfCoordinator)).measure(address(roulette), requestId, words);
    }

    function test_LogHouseGas() public {
        uint256[2][6] memory cases = [
            [uint256(1), 0], [uint256(1), 1], [uint256(10), 0], [uint256(10), 3], [uint256(10), 10], [uint256(40), 40]
        ];
        for (uint256 k; k < cases.length; ++k) {
            uint256 snap = vm.snapshotState();
            (uint256 s, uint256 c) = _round(cases[k][0], cases[k][1]);
            vm.revertToState(snap);
            console.log("bets=%s winners=%s", cases[k][0], cases[k][1]);
            console.log("    spin=%s callback=%s", s, c);
        }
    }
}
