// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/**
 * @title RouletteTypes
 * @notice Library containing all types, structs, and constants for the Roulette game
 * @dev Implements European roulette with numbers 0-36.
 *      Bets store the numbers they cover as a 37-bit mask: bit n set = bet wins when n comes up.
 */
library RouletteTypes {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error RouletteTypes__NumberOutOfRange(uint8 number);

    /*//////////////////////////////////////////////////////////////
                            TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Enum representing the state of the roulette
    enum RouletteState {
        OPEN, // Accepting bets
        CALCULATING, // Spinning and calculating payouts, no bets allowed
        DEFICIT // Round settled but the vault could not cover it, no bets until covered
    }

    /// @notice Enum representing the color of a roulette number
    enum Color {
        GREEN, // 0
        RED, // 1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36
        BLACK // 2, 4, 6, 8, 10, 11, 13, 15, 17, 20, 22, 24, 26, 28, 29, 31, 33, 35
    }

    /// @notice Enum representing different types of bets
    enum BetType {
        STRAIGHT_UP, // Single number (0-36) - 35:1
        SPLIT, // Two adjacent numbers - 17:1
        STREET, // Three numbers in a row - 11:1
        CORNER, // Four numbers in a square - 8:1
        LINE, // Six numbers (two rows) - 5:1
        DOZEN, // 12 numbers (1-12, 13-24, 25-36) - 2:1
        COLUMN, // 12 numbers in a column - 2:1
        RED, // All red numbers - 1:1
        BLACK, // All black numbers - 1:1
        EVEN, // All even numbers (not 0) - 1:1
        ODD, // All odd numbers - 1:1
        LOW, // Numbers 1-18 - 1:1
        HIGH // Numbers 19-36 - 1:1
    }

    /// @notice A single bet, packed into one storage slot (20 + 1 + 5 + 6 bytes)
    struct Bet {
        address player;
        BetType betType;
        uint40 numbersMask; // bit n set = bet covers number n
        uint48 amount; // D6{USDC} stake; max ~281M USDC (6 decimals)
    }

    /// @notice A game round. Bets of a round have contiguous ids [firstBetId, lastBetId]
    struct Round {
        uint64 firstBetId;
        uint64 lastBetId;
        uint64 timestamp; // {s} time of the first bet
        uint8 winningNumber; // {pocket} 255 until settled
        Color winningColor;
        bool completed;
        bool refunded;
        uint128 totalBets; // D6{USDC} sum of stakes (NOT a count)
        uint128 totalPayout; // D6{USDC} gross: sum of payouts (stake + winnings) to winners
        // D6{USDC} = Σ D6{USDC} * D0{1}
        uint256 maxExposure; // D6{USDC} gross: sum of amount * (multiplier + 1), worst case if every bet wins
    }

    /// @notice Per-player statistics, laid out so losing bets need no write at settlement
    struct PlayerStats {
        // slot 0: written by placeBet
        uint32 totalBets; // {count} number of bets (NOT a USDC sum)
        uint40 lastPlayedTimestamp; // {s}
        uint64 lastRoundId; // {id} round of the player's last bet
        uint120 lastRoundWagered; // D6{USDC} stakes placed in lastRoundId
        // slot 1: written by placeBet
        uint256 totalWagered; // D6{USDC}
        // slot 2: written at settlement, winners only
        uint128 totalWon; // D6{USDC} net: winnings, without the returned stake
        uint128 totalWonStakes; // D6{USDC} stakes of winning bets
    }

    /// @notice Player statistics as returned to callers
    struct PlayerStatsView {
        uint256 totalBets; // {count}
        uint256 totalWagered; // D6{USDC}
        uint256 totalWon; // D6{USDC} net winnings (stake excluded)
        uint256 totalLost; // D6{USDC}
        uint256 lastPlayedTimestamp; // {s}
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/
    uint8 internal constant MAX_NUMBER = 36; // {pocket}
    uint256 internal constant WHEEL_SIZE = 37; // {count} pockets on the wheel

    uint40 internal constant RED_MASK = 0x154aad52aa;
    uint40 internal constant BLACK_MASK = 0xab552ad54;
    uint40 internal constant EVEN_MASK = 0x1555555554;
    uint40 internal constant ODD_MASK = 0xaaaaaaaaa;
    uint40 internal constant LOW_MASK = 0x7fffe;
    uint40 internal constant HIGH_MASK = 0x1ffff80000;
    uint40 internal constant DOZEN_1_MASK = 0x1ffe;
    uint40 internal constant DOZEN_2_MASK = 0x1ffe000;
    uint40 internal constant DOZEN_3_MASK = 0x1ffe000000;
    uint40 internal constant COLUMN_1_MASK = 0x492492492;
    uint40 internal constant COLUMN_2_MASK = 0x924924924;
    uint40 internal constant COLUMN_3_MASK = 0x1249249248;

    // Inside bet shapes on the table layout (rows 1-2-3, 4-5-6, ..., 34-35-36), shifted to their lowest number
    uint40 internal constant STREET_SHAPE = 0x7; // n, n+1, n+2
    uint40 internal constant CORNER_SHAPE = 0x1b; // n, n+1, n+3, n+4
    uint40 internal constant LINE_SHAPE = 0x3f; // n .. n+5
    uint40 internal constant FIRST_FOUR_MASK = 0xf; // 0, 1, 2, 3 (corner)

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Payout multipliers for each bet type (multiplied by bet amount)
    /// @return D0{1} winnings per unit stake (stake excluded); gross payout uses (mult + 1)
    function getPayoutMultiplier(BetType betType) internal pure returns (uint256) {
        if (betType == BetType.STRAIGHT_UP) return 35;
        if (betType == BetType.SPLIT) return 17;
        if (betType == BetType.STREET) return 11;
        if (betType == BetType.CORNER) return 8;
        if (betType == BetType.LINE) return 5;
        if (betType == BetType.DOZEN) return 2;
        if (betType == BetType.COLUMN) return 2;
        if (betType == BetType.RED) return 1;
        if (betType == BetType.BLACK) return 1;
        if (betType == BetType.EVEN) return 1;
        if (betType == BetType.ODD) return 1;
        if (betType == BetType.LOW) return 1;
        if (betType == BetType.HIGH) return 1;
        return 0;
    }

    /// @notice Get the color of a number
    function getNumberColor(uint8 number) internal pure returns (Color) {
        if (number == 0) return Color.GREEN;
        return (RED_MASK >> number) & 1 == 1 ? Color.RED : Color.BLACK;
    }

    /// @notice Validate bet based on bet type and numbers provided
    /// @dev Inside bets must be a real shape on the table, with distinct numbers in any order
    function validateBet(BetType betType, uint8[] memory numbers) internal pure returns (bool) {
        if (betType == BetType.STRAIGHT_UP) {
            return numbers.length == 1 && numbers[0] <= MAX_NUMBER;
        }
        if (betType == BetType.SPLIT) {
            return numbers.length == 2 && isValidSplit(numbers[0], numbers[1]);
        }
        if (betType == BetType.STREET) return isValidStreet(numbers);
        if (betType == BetType.CORNER) return isValidCorner(numbers);
        if (betType == BetType.LINE) return isValidLine(numbers);
        if (betType == BetType.DOZEN || betType == BetType.COLUMN) {
            return numbers.length == 1 && numbers[0] >= 1 && numbers[0] <= 3;
        }
        // Simple bets don't need number validation
        if (
            betType == BetType.RED || betType == BetType.BLACK || betType == BetType.EVEN || betType == BetType.ODD
                || betType == BetType.LOW || betType == BetType.HIGH
        ) {
            return numbers.length == 0;
        }
        return false;
    }

    /// @notice Check if two numbers form a valid split: neighbours in a row or a column, or 0 with 1, 2 or 3
    function isValidSplit(uint8 num1, uint8 num2) internal pure returns (bool) {
        if (num1 > MAX_NUMBER || num2 > MAX_NUMBER) return false;
        (uint8 low, uint8 high) = num1 < num2 ? (num1, num2) : (num2, num1);
        if (low == 0) return high >= 1 && high <= 3;
        // Same row (low is not the row's last number), or same column in the next row
        return (high - low == 1 && low % 3 != 0) || high - low == 3;
    }

    /// @notice Check if numbers form a valid street (the three numbers of one row)
    function isValidStreet(uint8[] memory numbers) internal pure returns (bool) {
        (bool ok, uint40 mask, uint8 low) = _shape(numbers, 3);
        return ok && low % 3 == 1 && mask == STREET_SHAPE << low;
    }

    /// @notice Check if numbers form a valid corner (four numbers in a square, or 0-1-2-3)
    function isValidCorner(uint8[] memory numbers) internal pure returns (bool) {
        (bool ok, uint40 mask, uint8 low) = _shape(numbers, 4);
        if (!ok) return false;
        if (mask == FIRST_FOUR_MASK) return true;
        // low in the first or second column, so low + 1 is in the same row
        return low % 3 != 0 && mask == CORNER_SHAPE << low;
    }

    /// @notice Check if numbers form a valid line (the six numbers of two consecutive rows)
    function isValidLine(uint8[] memory numbers) internal pure returns (bool) {
        (bool ok, uint40 mask, uint8 low) = _shape(numbers, 6);
        return ok && low % 3 == 1 && mask == LINE_SHAPE << low;
    }

    /**
     * @notice Build the mask of numbers a bet covers
     * @dev Assumes validateBet passed. Reverts on numbers above 36 so no bit outside the wheel is set.
     */
    function toNumbersMask(BetType betType, uint8[] memory numbers) internal pure returns (uint40 mask) {
        if (betType == BetType.DOZEN) {
            if (numbers[0] == 1) return DOZEN_1_MASK;
            if (numbers[0] == 2) return DOZEN_2_MASK;
            return DOZEN_3_MASK;
        }
        if (betType == BetType.COLUMN) {
            if (numbers[0] == 1) return COLUMN_1_MASK;
            if (numbers[0] == 2) return COLUMN_2_MASK;
            return COLUMN_3_MASK;
        }
        if (betType == BetType.RED) return RED_MASK;
        if (betType == BetType.BLACK) return BLACK_MASK;
        if (betType == BetType.EVEN) return EVEN_MASK;
        if (betType == BetType.ODD) return ODD_MASK;
        if (betType == BetType.LOW) return LOW_MASK;
        if (betType == BetType.HIGH) return HIGH_MASK;

        // Inside bets: one bit per number
        for (uint256 i; i < numbers.length; ++i) {
            if (numbers[i] > MAX_NUMBER) revert RouletteTypes__NumberOutOfRange(numbers[i]);
            mask |= uint40(1) << numbers[i];
        }
    }

    /**
     * @dev Mask and lowest number of `count` distinct numbers, each <= 36. ok is false otherwise.
     *      A shape shifted past bit 36 can't match: its numbers would be above 36.
     */
    function _shape(uint8[] memory numbers, uint256 count) private pure returns (bool ok, uint40 mask, uint8 low) {
        if (numbers.length != count) return (false, 0, 0);
        low = type(uint8).max;
        for (uint256 i; i < count; ++i) {
            uint8 n = numbers[i];
            if (n > MAX_NUMBER) return (false, 0, 0);
            uint40 bit = uint40(1) << n;
            if (mask & bit != 0) return (false, 0, 0); // duplicate
            mask |= bit;
            if (n < low) low = n;
        }
        ok = true;
    }

    /// @notice Check if a bet wins based on the winning number
    function checkWin(uint40 numbersMask, uint8 winningNumber) internal pure returns (bool) {
        return (numbersMask >> winningNumber) & 1 == 1;
    }
}
