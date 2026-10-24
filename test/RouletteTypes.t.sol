// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {RouletteTypes} from "src/libraries/RouletteTypes.sol";

/**
 * @title RouletteTypesTest
 * @notice Tests for the RouletteTypes library
 */
contract RouletteTypesTest is Test {
    using RouletteTypes for *;

    // ============ Color Tests ============

    function test_GetNumberColor_Zero() public pure {
        assertEq(uint8(RouletteTypes.getNumberColor(0)), uint8(RouletteTypes.Color.GREEN));
    }

    function test_GetNumberColor_AllRed() public pure {
        uint8[18] memory redNumbers = [uint8(1), 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36];

        for (uint256 i = 0; i < redNumbers.length; i++) {
            assertEq(
                uint8(RouletteTypes.getNumberColor(redNumbers[i])),
                uint8(RouletteTypes.Color.RED),
                string(abi.encodePacked("Red number ", vm.toString(redNumbers[i]), " failed"))
            );
        }
    }

    function test_GetNumberColor_AllBlack() public pure {
        uint8[18] memory blackNumbers = [uint8(2), 4, 6, 8, 10, 11, 13, 15, 17, 20, 22, 24, 26, 28, 29, 31, 33, 35];

        for (uint256 i = 0; i < blackNumbers.length; i++) {
            assertEq(
                uint8(RouletteTypes.getNumberColor(blackNumbers[i])),
                uint8(RouletteTypes.Color.BLACK),
                string(abi.encodePacked("Black number ", vm.toString(blackNumbers[i]), " failed"))
            );
        }
    }

    function test_GetNumberColor_AllNumbers() public pure {
        // Test all numbers 0-36
        for (uint8 i = 0; i <= 36; i++) {
            RouletteTypes.Color color = RouletteTypes.getNumberColor(i);

            // Verify color is valid
            assertTrue(
                color == RouletteTypes.Color.GREEN || color == RouletteTypes.Color.RED
                    || color == RouletteTypes.Color.BLACK,
                string(abi.encodePacked("Invalid color for number ", vm.toString(i)))
            );
        }
    }

    // ============ Payout Multiplier Tests ============

    function test_GetPayoutMultiplier_AllTypes() public pure {
        assertEq(RouletteTypes.getPayoutMultiplier(RouletteTypes.BetType.STRAIGHT_UP), 35);
        assertEq(RouletteTypes.getPayoutMultiplier(RouletteTypes.BetType.SPLIT), 17);
        assertEq(RouletteTypes.getPayoutMultiplier(RouletteTypes.BetType.STREET), 11);
        assertEq(RouletteTypes.getPayoutMultiplier(RouletteTypes.BetType.CORNER), 8);
        assertEq(RouletteTypes.getPayoutMultiplier(RouletteTypes.BetType.LINE), 5);
        assertEq(RouletteTypes.getPayoutMultiplier(RouletteTypes.BetType.DOZEN), 2);
        assertEq(RouletteTypes.getPayoutMultiplier(RouletteTypes.BetType.COLUMN), 2);
        assertEq(RouletteTypes.getPayoutMultiplier(RouletteTypes.BetType.RED), 1);
        assertEq(RouletteTypes.getPayoutMultiplier(RouletteTypes.BetType.BLACK), 1);
        assertEq(RouletteTypes.getPayoutMultiplier(RouletteTypes.BetType.EVEN), 1);
        assertEq(RouletteTypes.getPayoutMultiplier(RouletteTypes.BetType.ODD), 1);
        assertEq(RouletteTypes.getPayoutMultiplier(RouletteTypes.BetType.LOW), 1);
        assertEq(RouletteTypes.getPayoutMultiplier(RouletteTypes.BetType.HIGH), 1);
    }

    // ============ Validation Tests ============

    function test_ValidateBet_StraightUp_Valid() public pure {
        uint8[] memory validNumbers = new uint8[](1);
        validNumbers[0] = 17;
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.STRAIGHT_UP, validNumbers));

        validNumbers[0] = 0;
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.STRAIGHT_UP, validNumbers));

        validNumbers[0] = 36;
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.STRAIGHT_UP, validNumbers));
    }

    function test_ValidateBet_StraightUp_Invalid() public pure {
        uint8[] memory invalidNumbers = new uint8[](1);
        invalidNumbers[0] = 37;
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.STRAIGHT_UP, invalidNumbers));

        uint8[] memory tooMany = new uint8[](2);
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.STRAIGHT_UP, tooMany));

        uint8[] memory empty = new uint8[](0);
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.STRAIGHT_UP, empty));
    }

    function test_ValidateBet_SimpleBets() public pure {
        uint8[] memory empty = new uint8[](0);

        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.RED, empty));
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.BLACK, empty));
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.EVEN, empty));
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.ODD, empty));
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.LOW, empty));
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.HIGH, empty));
    }

    function test_ValidateBet_Dozen() public pure {
        uint8[] memory valid1 = new uint8[](1);
        valid1[0] = 1;
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.DOZEN, valid1));

        uint8[] memory valid2 = new uint8[](1);
        valid2[0] = 2;
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.DOZEN, valid2));

        uint8[] memory valid3 = new uint8[](1);
        valid3[0] = 3;
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.DOZEN, valid3));

        uint8[] memory invalid = new uint8[](1);
        invalid[0] = 4;
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.DOZEN, invalid));

        invalid[0] = 0;
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.DOZEN, invalid));
    }

    function test_ValidateBet_Column() public pure {
        uint8[] memory valid1 = new uint8[](1);
        valid1[0] = 1;
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.COLUMN, valid1));

        uint8[] memory valid2 = new uint8[](1);
        valid2[0] = 2;
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.COLUMN, valid2));

        uint8[] memory valid3 = new uint8[](1);
        valid3[0] = 3;
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.COLUMN, valid3));
    }

    // ============ Check Win Tests ============

    function test_CheckWin_StraightUp() public pure {
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = 17;

        assertTrue(_win(RouletteTypes.BetType.STRAIGHT_UP, numbers, 17));
        assertFalse(_win(RouletteTypes.BetType.STRAIGHT_UP, numbers, 18));
        assertFalse(_win(RouletteTypes.BetType.STRAIGHT_UP, numbers, 0));
    }

    function test_CheckWin_Red() public pure {
        uint8[] memory numbers = new uint8[](0);

        // Test with red numbers
        assertTrue(_win(RouletteTypes.BetType.RED, numbers, 1));
        assertTrue(_win(RouletteTypes.BetType.RED, numbers, 3));
        assertTrue(_win(RouletteTypes.BetType.RED, numbers, 36));

        // Test with black numbers
        assertFalse(_win(RouletteTypes.BetType.RED, numbers, 2));
        assertFalse(_win(RouletteTypes.BetType.RED, numbers, 4));

        // Test with green (0)
        assertFalse(_win(RouletteTypes.BetType.RED, numbers, 0));
    }

    function test_CheckWin_Black() public pure {
        uint8[] memory numbers = new uint8[](0);

        assertTrue(_win(RouletteTypes.BetType.BLACK, numbers, 2));
        assertTrue(_win(RouletteTypes.BetType.BLACK, numbers, 4));
        assertTrue(_win(RouletteTypes.BetType.BLACK, numbers, 35));
        assertFalse(_win(RouletteTypes.BetType.BLACK, numbers, 1));
        assertFalse(_win(RouletteTypes.BetType.BLACK, numbers, 0));
    }

    function test_CheckWin_Even() public pure {
        uint8[] memory numbers = new uint8[](0);

        assertTrue(_win(RouletteTypes.BetType.EVEN, numbers, 2));
        assertTrue(_win(RouletteTypes.BetType.EVEN, numbers, 36));
        assertFalse(_win(RouletteTypes.BetType.EVEN, numbers, 1));
        assertFalse(_win(RouletteTypes.BetType.EVEN, numbers, 35));
        assertFalse(_win(RouletteTypes.BetType.EVEN, numbers, 0));
    }

    function test_CheckWin_Odd() public pure {
        uint8[] memory numbers = new uint8[](0);

        assertTrue(_win(RouletteTypes.BetType.ODD, numbers, 1));
        assertTrue(_win(RouletteTypes.BetType.ODD, numbers, 35));
        assertFalse(_win(RouletteTypes.BetType.ODD, numbers, 2));
        assertFalse(_win(RouletteTypes.BetType.ODD, numbers, 36));
        assertFalse(_win(RouletteTypes.BetType.ODD, numbers, 0));
    }

    function test_CheckWin_Low() public pure {
        uint8[] memory numbers = new uint8[](0);

        assertTrue(_win(RouletteTypes.BetType.LOW, numbers, 1));
        assertTrue(_win(RouletteTypes.BetType.LOW, numbers, 18));
        assertFalse(_win(RouletteTypes.BetType.LOW, numbers, 19));
        assertFalse(_win(RouletteTypes.BetType.LOW, numbers, 36));
        assertFalse(_win(RouletteTypes.BetType.LOW, numbers, 0));
    }

    function test_CheckWin_High() public pure {
        uint8[] memory numbers = new uint8[](0);

        assertTrue(_win(RouletteTypes.BetType.HIGH, numbers, 19));
        assertTrue(_win(RouletteTypes.BetType.HIGH, numbers, 36));
        assertFalse(_win(RouletteTypes.BetType.HIGH, numbers, 18));
        assertFalse(_win(RouletteTypes.BetType.HIGH, numbers, 1));
        assertFalse(_win(RouletteTypes.BetType.HIGH, numbers, 0));
    }

    function test_CheckWin_Dozen() public pure {
        uint8[] memory dozen1 = new uint8[](1);
        dozen1[0] = 1;
        assertTrue(_win(RouletteTypes.BetType.DOZEN, dozen1, 1));
        assertTrue(_win(RouletteTypes.BetType.DOZEN, dozen1, 12));
        assertFalse(_win(RouletteTypes.BetType.DOZEN, dozen1, 13));
        assertFalse(_win(RouletteTypes.BetType.DOZEN, dozen1, 0));

        uint8[] memory dozen2 = new uint8[](1);
        dozen2[0] = 2;
        assertTrue(_win(RouletteTypes.BetType.DOZEN, dozen2, 13));
        assertTrue(_win(RouletteTypes.BetType.DOZEN, dozen2, 24));
        assertFalse(_win(RouletteTypes.BetType.DOZEN, dozen2, 12));
        assertFalse(_win(RouletteTypes.BetType.DOZEN, dozen2, 25));

        uint8[] memory dozen3 = new uint8[](1);
        dozen3[0] = 3;
        assertTrue(_win(RouletteTypes.BetType.DOZEN, dozen3, 25));
        assertTrue(_win(RouletteTypes.BetType.DOZEN, dozen3, 36));
        assertFalse(_win(RouletteTypes.BetType.DOZEN, dozen3, 24));
    }

    function test_CheckWin_Column() public pure {
        uint8[] memory column1 = new uint8[](1);
        column1[0] = 1;
        assertTrue(_win(RouletteTypes.BetType.COLUMN, column1, 1));
        assertTrue(_win(RouletteTypes.BetType.COLUMN, column1, 4));
        assertTrue(_win(RouletteTypes.BetType.COLUMN, column1, 34));
        assertFalse(_win(RouletteTypes.BetType.COLUMN, column1, 2));
        assertFalse(_win(RouletteTypes.BetType.COLUMN, column1, 0));

        uint8[] memory column2 = new uint8[](1);
        column2[0] = 2;
        assertTrue(_win(RouletteTypes.BetType.COLUMN, column2, 2));
        assertTrue(_win(RouletteTypes.BetType.COLUMN, column2, 5));
        assertTrue(_win(RouletteTypes.BetType.COLUMN, column2, 35));
        assertFalse(_win(RouletteTypes.BetType.COLUMN, column2, 1));

        uint8[] memory column3 = new uint8[](1);
        column3[0] = 3;
        assertTrue(_win(RouletteTypes.BetType.COLUMN, column3, 3));
        assertTrue(_win(RouletteTypes.BetType.COLUMN, column3, 6));
        assertTrue(_win(RouletteTypes.BetType.COLUMN, column3, 36));
        assertFalse(_win(RouletteTypes.BetType.COLUMN, column3, 1));
    }

    // ============ Helper Function Tests ============

    function test_IsValidSplit() public pure {
        // Adjacent horizontal
        assertTrue(RouletteTypes.isValidSplit(1, 2));
        assertTrue(RouletteTypes.isValidSplit(35, 36));

        // Adjacent vertical
        assertTrue(RouletteTypes.isValidSplit(1, 4));
        assertTrue(RouletteTypes.isValidSplit(34, 31));

        // Not adjacent
        assertFalse(RouletteTypes.isValidSplit(1, 5));
        assertFalse(RouletteTypes.isValidSplit(1, 10));

        // Invalid numbers
        assertFalse(RouletteTypes.isValidSplit(37, 1));
        assertFalse(RouletteTypes.isValidSplit(1, 38));
    }

    // ============ Fuzz Tests ============

    function testFuzz_GetNumberColor(uint8 number) public pure {
        vm.assume(number <= 36);

        RouletteTypes.Color color = RouletteTypes.getNumberColor(number);

        // Check color is valid
        assertTrue(
            color == RouletteTypes.Color.GREEN || color == RouletteTypes.Color.RED || color == RouletteTypes.Color.BLACK
        );

        // Zero should always be green
        if (number == 0) {
            assertEq(uint8(color), uint8(RouletteTypes.Color.GREEN));
        }
    }

    function testFuzz_CheckWin_StraightUp(uint8 betNumber, uint8 winningNumber) public pure {
        vm.assume(betNumber <= 36);
        vm.assume(winningNumber <= 36);

        uint8[] memory numbers = new uint8[](1);
        numbers[0] = betNumber;

        bool shouldWin = (betNumber == winningNumber);
        bool actualWin = _win(RouletteTypes.BetType.STRAIGHT_UP, numbers, winningNumber);

        assertEq(shouldWin, actualWin);
    }

    function testFuzz_CheckWin_Even(uint8 winningNumber) public pure {
        vm.assume(winningNumber <= 36);

        uint8[] memory numbers = new uint8[](0);
        bool result = _win(RouletteTypes.BetType.EVEN, numbers, winningNumber);

        // Should win only if number is even and not zero
        bool expected = (winningNumber > 0 && winningNumber % 2 == 0);
        assertEq(result, expected);
    }

    function testFuzz_CheckWin_Odd(uint8 winningNumber) public pure {
        vm.assume(winningNumber <= 36);

        uint8[] memory numbers = new uint8[](0);
        bool result = _win(RouletteTypes.BetType.ODD, numbers, winningNumber);

        // Should win only if number is odd and not zero
        bool expected = (winningNumber > 0 && winningNumber % 2 == 1);
        assertEq(result, expected);
    }

    // ============ Numbers Mask Tests ============

    /// @dev Reference implementation of the pre-mask win rules, used to check the masks
    function _referenceWin(RouletteTypes.BetType betType, uint8[] memory numbers, uint8 n)
        internal
        pure
        returns (bool)
    {
        if (uint8(betType) <= uint8(RouletteTypes.BetType.LINE)) {
            for (uint256 i; i < numbers.length; ++i) {
                if (numbers[i] == n) return true;
            }
            return false;
        }
        if (n == 0) return false;
        if (betType == RouletteTypes.BetType.DOZEN) return (n - 1) / 12 + 1 == numbers[0];
        if (betType == RouletteTypes.BetType.COLUMN) return n % 3 == numbers[0] % 3;
        // Explicit red list: getNumberColor is derived from RED_MASK, so it can't be the reference
        if (betType == RouletteTypes.BetType.RED) return _isRed(n);
        if (betType == RouletteTypes.BetType.BLACK) return !_isRed(n);
        if (betType == RouletteTypes.BetType.EVEN) return n % 2 == 0;
        if (betType == RouletteTypes.BetType.ODD) return n % 2 == 1;
        if (betType == RouletteTypes.BetType.LOW) return n <= 18;
        return n >= 19;
    }

    function _isRed(uint8 n) internal pure returns (bool) {
        uint8[18] memory reds = [1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36];
        for (uint256 i; i < 18; ++i) {
            if (reds[i] == n) return true;
        }
        return false;
    }

    function _countBits(uint40 mask) internal pure returns (uint256 count) {
        for (; mask != 0; mask &= mask - 1) {
            ++count;
        }
    }

    /// @dev Exhaustive over all outside bets and all 37 pockets (the domain is small enough to enumerate)
    function test_Mask_OutsideBetsMatchReference_AllPockets() public pure {
        for (uint8 t = 5; t <= 12; ++t) {
            RouletteTypes.BetType betType = RouletteTypes.BetType(t);
            uint8 selectors =
                (betType == RouletteTypes.BetType.DOZEN || betType == RouletteTypes.BetType.COLUMN) ? 3 : 1;
            for (uint8 sel = 1; sel <= selectors; ++sel) {
                uint8[] memory numbers;
                if (selectors == 3) {
                    numbers = new uint8[](1);
                    numbers[0] = sel;
                }
                for (uint8 n; n <= 36; ++n) {
                    assertEq(_win(betType, numbers, n), _referenceWin(betType, numbers, n));
                }
            }
        }
    }

    function testFuzz_Mask_StraightUpCoversOnlyItsNumber(uint8 number, uint8 n) public pure {
        number = uint8(bound(number, 0, 36));
        n = uint8(bound(n, 0, 36));
        uint8[] memory numbers = new uint8[](1);
        numbers[0] = number;
        uint40 mask = RouletteTypes.toNumbersMask(RouletteTypes.BetType.STRAIGHT_UP, numbers);
        assertEq(_countBits(mask), 1);
        assertEq(RouletteTypes.checkWin(mask, n), n == number);
    }

    function testFuzz_Mask_InsideBetsMatchReference(uint8[6] memory raw, uint8 n) public pure {
        n = uint8(bound(n, 0, 36));
        uint8[] memory numbers = new uint8[](6);
        for (uint256 i; i < 6; ++i) {
            numbers[i] = uint8(bound(raw[i], 0, 36));
        }
        uint40 mask = RouletteTypes.toNumbersMask(RouletteTypes.BetType.LINE, numbers);
        assertEq(RouletteTypes.checkWin(mask, n), _referenceWin(RouletteTypes.BetType.LINE, numbers, n));
    }

    function testFuzz_Mask_RevertWhen_NumberAbove36(uint8 number) public {
        number = uint8(bound(number, 37, 255));
        uint8[] memory numbers = new uint8[](4);
        numbers[0] = 1;
        numbers[3] = number;
        vm.expectRevert(abi.encodeWithSelector(RouletteTypes.RouletteTypes__NumberOutOfRange.selector, number));
        this.externalToNumbersMask(RouletteTypes.BetType.CORNER, numbers);
    }

    function test_Mask_OutsideBetsCoverExpectedCount() public pure {
        uint8[] memory none;
        assertEq(_countBits(RouletteTypes.toNumbersMask(RouletteTypes.BetType.RED, none)), 18);
        assertEq(_countBits(RouletteTypes.toNumbersMask(RouletteTypes.BetType.BLACK, none)), 18);
        assertEq(_countBits(RouletteTypes.toNumbersMask(RouletteTypes.BetType.EVEN, none)), 18);
        assertEq(_countBits(RouletteTypes.toNumbersMask(RouletteTypes.BetType.ODD, none)), 18);
        assertEq(_countBits(RouletteTypes.toNumbersMask(RouletteTypes.BetType.LOW, none)), 18);
        assertEq(_countBits(RouletteTypes.toNumbersMask(RouletteTypes.BetType.HIGH, none)), 18);
        assertEq(RouletteTypes.RED_MASK & RouletteTypes.BLACK_MASK, 0);
        assertEq(RouletteTypes.RED_MASK | RouletteTypes.BLACK_MASK, RouletteTypes.LOW_MASK | RouletteTypes.HIGH_MASK);
        for (uint8 selector = 1; selector <= 3; ++selector) {
            uint8[] memory numbers = new uint8[](1);
            numbers[0] = selector;
            assertEq(_countBits(RouletteTypes.toNumbersMask(RouletteTypes.BetType.DOZEN, numbers)), 12);
            assertEq(_countBits(RouletteTypes.toNumbersMask(RouletteTypes.BetType.COLUMN, numbers)), 12);
        }
    }

    function externalToNumbersMask(RouletteTypes.BetType betType, uint8[] memory numbers)
        external
        pure
        returns (uint40)
    {
        return RouletteTypes.toNumbersMask(betType, numbers);
    }

    function _win(RouletteTypes.BetType betType, uint8[] memory numbers, uint8 n) internal pure returns (bool) {
        return RouletteTypes.checkWin(RouletteTypes.toNumbersMask(betType, numbers), n);
    }
}
