// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title RouletteTypes
 * @notice Library containing all types, structs, and constants for the Roulette game
 * @dev Implements European roulette with numbers 0-36
 */
library RouletteTypes {
    /// @notice Enum representing the state of the roulette
    enum RouletteState {
        OPEN,         // Accepting bets
        CALCULATING   // Spinning and calculating payouts, no bets allowed
    }

    /// @notice Enum representing the color of a roulette number
    enum Color {
        GREEN, // 0
        RED,   // 1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36
        BLACK  // 2, 4, 6, 8, 10, 11, 13, 15, 17, 20, 22, 24, 26, 28, 29, 31, 33, 35
    }

    /// @notice Enum representing different types of bets
    enum BetType {
        STRAIGHT_UP,    // Single number (0-36) - 35:1
        SPLIT,          // Two adjacent numbers - 17:1
        STREET,         // Three numbers in a row - 11:1
        CORNER,         // Four numbers in a square - 8:1
        LINE,           // Six numbers (two rows) - 5:1
        DOZEN,          // 12 numbers (1-12, 13-24, 25-36) - 2:1
        COLUMN,         // 12 numbers in a column - 2:1
        RED,            // All red numbers - 1:1
        BLACK,          // All black numbers - 1:1
        EVEN,           // All even numbers (not 0) - 1:1
        ODD,            // All odd numbers - 1:1
        LOW,            // Numbers 1-18 - 1:1
        HIGH            // Numbers 19-36 - 1:1
    }

    /// @notice Struct representing a single bet
    struct Bet {
        address player;
        uint256 amount;
        BetType betType;
        uint8[] numbers; // Numbers selected for the bet
        uint256 timestamp;
        bool settled;
        bool won;
        uint256 payout;
    }

    /// @notice Struct representing a game round
    struct Round {
        uint256 roundId;
        uint256 requestId; // Chainlink VRF request ID
        uint8 winningNumber;
        Color winningColor;
        uint256 timestamp;
        bool completed;
        uint256 totalBets;
        uint256 totalPayout;
    }

    /// @notice Struct to track player statistics
    struct PlayerStats {
        uint256 totalBets;
        uint256 totalWagered;
        uint256 totalWon;
        uint256 totalLost;
        uint256 lastPlayedTimestamp;
    }

    /// @notice Payout multipliers for each bet type (multiplied by bet amount)
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
        
        // Red numbers in European roulette
        if (
            number == 1 || number == 3 || number == 5 || number == 7 || number == 9 ||
            number == 12 || number == 14 || number == 16 || number == 18 ||
            number == 19 || number == 21 || number == 23 || number == 25 || number == 27 ||
            number == 30 || number == 32 || number == 34 || number == 36
        ) {
            return Color.RED;
        }
        
        return Color.BLACK;
    }

    /// @notice Check if a number is in the provided array
    function isNumberInArray(uint8 number, uint8[] memory numbers) internal pure returns (bool) {
        for (uint256 i = 0; i < numbers.length; i++) {
            if (numbers[i] == number) return true;
        }
        return false;
    }

    /// @notice Validate bet based on bet type and numbers provided
    function validateBet(BetType betType, uint8[] memory numbers) internal pure returns (bool) {
        if (betType == BetType.STRAIGHT_UP) {
            return numbers.length == 1 && numbers[0] <= 36;
        }
        if (betType == BetType.SPLIT) {
            return numbers.length == 2 && isValidSplit(numbers[0], numbers[1]);
        }
        if (betType == BetType.STREET) {
            return numbers.length == 3 && isValidStreet(numbers);
        }
        if (betType == BetType.CORNER) {
            return numbers.length == 4 && isValidCorner(numbers);
        }
        if (betType == BetType.LINE) {
            return numbers.length == 6 && isValidLine(numbers);
        }
        if (betType == BetType.DOZEN) {
            return numbers.length == 1 && numbers[0] >= 1 && numbers[0] <= 3;
        }
        if (betType == BetType.COLUMN) {
            return numbers.length == 1 && numbers[0] >= 1 && numbers[0] <= 3;
        }
        // Simple bets don't need number validation
        if (
            betType == BetType.RED || betType == BetType.BLACK ||
            betType == BetType.EVEN || betType == BetType.ODD ||
            betType == BetType.LOW || betType == BetType.HIGH
        ) {
            return numbers.length == 0;
        }
        return false;
    }

    /// @notice Check if two numbers form a valid split
    function isValidSplit(uint8 num1, uint8 num2) internal pure returns (bool) {
        if (num1 > 36 || num2 > 36) return false;
        uint256 diff = num1 > num2 ? num1 - num2 : num2 - num1;
        return diff == 1 || diff == 3;
    }

    /// @notice Check if numbers form a valid street (three consecutive numbers in a row)
    function isValidStreet(uint8[] memory numbers) internal pure returns (bool) {
        if (numbers.length != 3) return false;
        // Sort numbers
        uint8 min = numbers[0];
        uint8 max = numbers[0];
        for (uint256 i = 1; i < 3; i++) {
            if (numbers[i] < min) min = numbers[i];
            if (numbers[i] > max) max = numbers[i];
        }
        return (max - min == 2) && (min % 3 == 1);
    }

    /// @notice Check if numbers form a valid corner (four numbers in a square)
    function isValidCorner(uint8[] memory numbers) internal pure returns (bool) {
        if (numbers.length != 4) return false;
        // Implementation would check if they form a square on the table
        return true; // Simplified for now
    }

    /// @notice Check if numbers form a valid line (two consecutive rows)
    function isValidLine(uint8[] memory numbers) internal pure returns (bool) {
        if (numbers.length != 6) return false;
        // Implementation would check if they form two consecutive rows
        return true; // Simplified for now
    }

    /// @notice Check if a bet wins based on the winning number
    function checkWin(BetType betType, uint8[] memory numbers, uint8 winningNumber) 
        internal 
        pure 
        returns (bool) 
    {
        if (betType == BetType.STRAIGHT_UP) {
            return numbers[0] == winningNumber;
        }
        if (betType == BetType.SPLIT || betType == BetType.STREET || 
            betType == BetType.CORNER || betType == BetType.LINE) {
            return isNumberInArray(winningNumber, numbers);
        }
        if (betType == BetType.DOZEN) {
            uint8 dozen = numbers[0];
            if (dozen == 1) return winningNumber >= 1 && winningNumber <= 12;
            if (dozen == 2) return winningNumber >= 13 && winningNumber <= 24;
            if (dozen == 3) return winningNumber >= 25 && winningNumber <= 36;
        }
        if (betType == BetType.COLUMN) {
            uint8 column = numbers[0];
            if (winningNumber == 0) return false;
            return (winningNumber % 3) == (column % 3);
        }
        if (betType == BetType.RED) {
            return getNumberColor(winningNumber) == Color.RED;
        }
        if (betType == BetType.BLACK) {
            return getNumberColor(winningNumber) == Color.BLACK;
        }
        if (betType == BetType.EVEN) {
            return winningNumber > 0 && winningNumber % 2 == 0;
        }
        if (betType == BetType.ODD) {
            return winningNumber > 0 && winningNumber % 2 == 1;
        }
        if (betType == BetType.LOW) {
            return winningNumber >= 1 && winningNumber <= 18;
        }
        if (betType == BetType.HIGH) {
            return winningNumber >= 19 && winningNumber <= 36;
        }
        return false;
    }
}
