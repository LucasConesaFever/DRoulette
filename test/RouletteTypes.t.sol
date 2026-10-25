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

        // Zero splits with 1, 2 and 3
        assertTrue(RouletteTypes.isValidSplit(0, 1));
        assertTrue(RouletteTypes.isValidSplit(2, 0));
        assertTrue(RouletteTypes.isValidSplit(0, 3));
        assertFalse(RouletteTypes.isValidSplit(0, 4));

        // Not adjacent: row ends, gaps, same number
        assertFalse(RouletteTypes.isValidSplit(3, 4));
        assertFalse(RouletteTypes.isValidSplit(6, 7));
        assertFalse(RouletteTypes.isValidSplit(1, 5));
        assertFalse(RouletteTypes.isValidSplit(1, 10));
        assertFalse(RouletteTypes.isValidSplit(5, 5));
        assertFalse(RouletteTypes.isValidSplit(0, 0));

        // Invalid numbers
        assertFalse(RouletteTypes.isValidSplit(37, 1));
        assertFalse(RouletteTypes.isValidSplit(1, 38));
        assertFalse(RouletteTypes.isValidSplit(36, 37));
    }

    // ============ Table Geometry Tests ============

    /// @dev Exhaustive: every ordered pair of 0..37 against the reference layout
    function test_IsValidSplit_AllPairsMatchReference() public pure {
        uint256 valid;
        for (uint8 a; a <= 37; ++a) {
            for (uint8 b; b <= 37; ++b) {
                bool expected = _refSplit(a, b);
                assertEq(RouletteTypes.isValidSplit(a, b), expected);
                if (expected) ++valid;
            }
        }
        // 24 in rows + 33 in columns + 3 with zero, each in both orders
        assertEq(valid, 120);
    }

    /// @dev Exhaustive: every set of three numbers in 0..37, in two orders, against the reference layout
    function test_IsValidStreet_AllTriplesMatchReference() public pure {
        uint256 valid;
        uint8[] memory numbers = new uint8[](3);
        for (uint8 a; a <= 37; ++a) {
            for (uint8 b = a + 1; b <= 37; ++b) {
                for (uint8 c = b + 1; c <= 37; ++c) {
                    (numbers[0], numbers[1], numbers[2]) = (a, b, c);
                    bool expected = _refBox(numbers, 1, 3);
                    assertEq(RouletteTypes.isValidStreet(numbers), expected);
                    (numbers[0], numbers[1], numbers[2]) = (c, a, b);
                    assertEq(RouletteTypes.isValidStreet(numbers), expected);
                    if (expected) ++valid;
                }
            }
        }
        assertEq(valid, 12);
    }

    function testFuzz_IsValidCorner_MatchesReference(uint8[4] memory raw) public pure {
        uint8[] memory numbers = new uint8[](4);
        for (uint256 i; i < 4; ++i) {
            numbers[i] = uint8(bound(raw[i], 0, 37));
        }
        assertEq(RouletteTypes.isValidCorner(numbers), _refCorner(numbers));
    }

    function testFuzz_IsValidLine_MatchesReference(uint8[6] memory raw) public pure {
        uint8[] memory numbers = new uint8[](6);
        for (uint256 i; i < 6; ++i) {
            numbers[i] = uint8(bound(raw[i], 0, 37));
        }
        assertEq(RouletteTypes.isValidLine(numbers), _refBox(numbers, 2, 3));
    }

    /// @dev Random sets are almost never valid, so build valid shapes from the layout, shuffled, then break them
    function testFuzz_InsideShapes_ValidAcceptedBrokenRejected(uint256 rowSeed, uint256 colSeed, uint256 shuffleSeed)
        public
        pure
    {
        uint8 row = uint8(rowSeed % 11); // 0..10, so row + 1 exists
        uint8 col = uint8(colSeed % 2); // 0..1, so col + 1 exists
        uint8 n = row * 3 + col + 1;

        uint8[] memory street = _numbers3(row * 3 + 1, row * 3 + 2, row * 3 + 3);
        uint8[] memory corner = _numbers4(n, n + 1, n + 3, n + 4);
        uint8[] memory line = new uint8[](6);
        for (uint8 i; i < 6; ++i) {
            line[i] = row * 3 + 1 + i;
        }
        _shuffle(street, shuffleSeed);
        _shuffle(corner, shuffleSeed);
        _shuffle(line, shuffleSeed);

        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.STREET, street));
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.CORNER, corner));
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.LINE, line));
        assertTrue(RouletteTypes.isValidSplit(n, n + 1));
        assertTrue(RouletteTypes.isValidSplit(n + 3, n));

        // A duplicate breaks every shape
        street[0] = street[1];
        corner[0] = corner[1];
        line[0] = line[1];
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.STREET, street));
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.CORNER, corner));
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.LINE, line));
    }

    function test_ValidateBet_RejectsBadInsideBets() public pure {
        // Split: wrong count, not adjacent
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.SPLIT, _numbers1(1)));
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.SPLIT, _numbers3(1, 2, 3)));
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.SPLIT, _numbers2(1, 5)));
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.SPLIT, _numbers2(3, 4)));
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.SPLIT, _numbers2(0, 2)));

        // Street: wrong count, wrong row, duplicate, above 36
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.STREET, _numbers2(1, 2)));
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.STREET, _numbers4(1, 2, 3, 4)));
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.STREET, _numbers3(2, 3, 4)));
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.STREET, _numbers3(1, 2, 4)));
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.STREET, _numbers3(1, 1, 3)));
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.STREET, _numbers3(35, 36, 37)));
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.STREET, _numbers3(36, 34, 35)));

        // Corner: wrong count, not a square, first four
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.CORNER, _numbers3(1, 2, 4)));
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.CORNER, _numbers4(2, 3, 4, 5)));
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.CORNER, _numbers4(3, 4, 6, 7)));
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.CORNER, _numbers4(2, 3, 5, 6)));
        assertTrue(RouletteTypes.validateBet(RouletteTypes.BetType.CORNER, _numbers4(3, 0, 2, 1)));

        // Line: wrong count, rows not aligned
        uint8[] memory five = new uint8[](5);
        uint8[] memory shifted = new uint8[](6);
        for (uint8 i; i < 6; ++i) {
            if (i < 5) five[i] = i + 1;
            shifted[i] = i + 2;
        }
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.LINE, five));
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.LINE, shifted));
    }

    function test_ValidateBet_RejectsWrongCountForOutsideBets() public pure {
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.DOZEN, new uint8[](0)));
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.DOZEN, _numbers2(1, 2)));
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.COLUMN, new uint8[](0)));
        assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType.COLUMN, _numbers2(1, 2)));
        for (uint8 t = uint8(RouletteTypes.BetType.RED); t <= uint8(RouletteTypes.BetType.HIGH); ++t) {
            assertFalse(RouletteTypes.validateBet(RouletteTypes.BetType(t), _numbers1(1)));
        }
    }

    /// @dev Reference layout: n >= 1 is at row (n - 1) / 3, column (n - 1) % 3; 0 sits above 1, 2 and 3
    function _refSplit(uint8 a, uint8 b) internal pure returns (bool) {
        if (a > 36 || b > 36 || a == b) return false;
        if (a == 0 || b == 0) return a + b <= 3;
        (uint256 rowA, uint256 colA) = ((a - 1) / 3, (a - 1) % 3);
        (uint256 rowB, uint256 colB) = ((b - 1) / 3, (b - 1) % 3);
        return (rowA == rowB && _absDiff(colA, colB) == 1) || (colA == colB && _absDiff(rowA, rowB) == 1);
    }

    /// @dev Reference: rows * cols distinct numbers in 1..36 whose rows and columns span exactly a rows x cols box
    function _refBox(uint8[] memory numbers, uint256 rows, uint256 cols) internal pure returns (bool) {
        if (numbers.length != rows * cols) return false;
        (uint256 minRow, uint256 maxRow, uint256 minCol, uint256 maxCol) = (type(uint256).max, 0, type(uint256).max, 0);
        for (uint256 i; i < numbers.length; ++i) {
            uint8 n = numbers[i];
            if (n == 0 || n > 36) return false;
            for (uint256 j; j < i; ++j) {
                if (numbers[j] == n) return false;
            }
            (uint256 row, uint256 col) = ((n - 1) / 3, (n - 1) % 3);
            if (row < minRow) minRow = row;
            if (row > maxRow) maxRow = row;
            if (col < minCol) minCol = col;
            if (col > maxCol) maxCol = col;
        }
        return maxRow - minRow + 1 == rows && maxCol - minCol + 1 == cols;
    }

    function _refCorner(uint8[] memory numbers) internal pure returns (bool) {
        // First four: 0, 1, 2, 3 in any order
        bool[4] memory seen;
        bool firstFour = true;
        for (uint256 i; i < 4; ++i) {
            if (numbers[i] > 3 || seen[numbers[i]]) {
                firstFour = false;
                break;
            }
            seen[numbers[i]] = true;
        }
        return firstFour || _refBox(numbers, 2, 2);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _shuffle(uint8[] memory numbers, uint256 seed) internal pure {
        for (uint256 i = numbers.length - 1; i > 0; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % (i + 1);
            (numbers[i], numbers[j]) = (numbers[j], numbers[i]);
        }
    }

    function _numbers1(uint8 a) internal pure returns (uint8[] memory numbers) {
        numbers = new uint8[](1);
        numbers[0] = a;
    }

    function _numbers2(uint8 a, uint8 b) internal pure returns (uint8[] memory numbers) {
        numbers = new uint8[](2);
        (numbers[0], numbers[1]) = (a, b);
    }

    function _numbers3(uint8 a, uint8 b, uint8 c) internal pure returns (uint8[] memory numbers) {
        numbers = new uint8[](3);
        (numbers[0], numbers[1], numbers[2]) = (a, b, c);
    }

    function _numbers4(uint8 a, uint8 b, uint8 c, uint8 d) internal pure returns (uint8[] memory numbers) {
        numbers = new uint8[](4);
        (numbers[0], numbers[1], numbers[2], numbers[3]) = (a, b, c, d);
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
