// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Imports
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./MockToken.sol";
import "./libraries/RouletteTypes.sol";

/**
 * @title Roulette
 * @notice Main contract for the decentralized roulette game (Phase 1)
 * @dev Uses MockToken for Phase 1 testing, implements European roulette (0-36)
 * Bets are always open except when calculating results (CALCULATING state)
 * This version uses a pseudo-random number generator - Phase 2 will integrate Chainlink VRF
 */
contract Roulette is Ownable, ReentrancyGuard, Pausable {
    // Type declarations
    using RouletteTypes for *;

    // Errors
    error RouletteNotOpen();
    error RouletteCalculating();
    error InvalidBetAmount();
    error InvalidNumbers();
    error NoActiveBets();
    error AlreadyCalculating();
    error SpinDelayNotMet(uint256 timeRemaining);

    // State variables
    MockToken public immutable bettingToken;
    RouletteTypes.RouletteState public state;
    uint256 public minBet;
    uint256 public maxBet;
    uint256 public houseEdge;
    uint256 public currentRoundId;
    uint256 public betIdCounter;
    uint256 public spinDelay;
    uint256 public lastSpinTimestamp;
    
    mapping(uint256 => RouletteTypes.Round) public rounds;
    mapping(uint256 => uint256[]) public roundBets;
    mapping(uint256 => RouletteTypes.Bet) public bets;
    mapping(address => RouletteTypes.PlayerStats) public playerStats;

    // Events
    event StateChanged(RouletteTypes.RouletteState indexed newState);
    event SpinRequested(uint256 indexed roundId, uint256 timestamp);
    event BetPlaced(
        uint256 indexed roundId,
        uint256 indexed betId,
        address indexed player,
        RouletteTypes.BetType betType,
        uint256 amount
    );
    event SpinCompleted(
        uint256 indexed roundId,
        uint8 winningNumber,
        RouletteTypes.Color winningColor,
        uint256 totalPayout
    );
    event BetSettled(
        uint256 indexed betId,
        address indexed player,
        bool won,
        uint256 payout
    );
    event MinBetUpdated(uint256 oldMinBet, uint256 newMinBet);
    event MaxBetUpdated(uint256 oldMaxBet, uint256 newMaxBet);
    event HouseEdgeUpdated(uint256 oldHouseEdge, uint256 newHouseEdge);
    event SpinDelayUpdated(uint256 oldDelay, uint256 newDelay);

    // Constructor
    /**
     * @notice Constructor
     * @param _bettingToken Address of the betting token
     * @param _minBet Minimum bet amount
     * @param _maxBet Maximum bet amount
     * @param _houseEdge House edge in basis points (270 = 2.7%)
     * @param _spinDelay Minimum delay between spins in seconds
     */
    constructor(
        address _bettingToken,
        uint256 _minBet,
        uint256 _maxBet,
        uint256 _houseEdge,
        uint256 _spinDelay
    ) Ownable(msg.sender) {
        bettingToken = MockToken(_bettingToken);
        minBet = _minBet;
        maxBet = _maxBet;
        houseEdge = _houseEdge;
        spinDelay = _spinDelay;
        state = RouletteTypes.RouletteState.OPEN;
        currentRoundId = 1;
        betIdCounter = 0;
        lastSpinTimestamp = 0;
    }

    // External functions
    /**
     * @notice Place a bet in the current round
     * @param betType Type of bet
     * @param numbers Numbers to bet on (depends on bet type)
     * @param amount Amount to bet
     */
    function placeBet(
        RouletteTypes.BetType betType,
        uint8[] calldata numbers,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (state != RouletteTypes.RouletteState.OPEN) revert RouletteNotOpen();
        if (amount < minBet || amount > maxBet) revert InvalidBetAmount();
        if (!RouletteTypes.validateBet(betType, numbers)) {
            revert InvalidNumbers();
        }

        bettingToken.burn(msg.sender, amount);

        betIdCounter++;
        bets[betIdCounter] = RouletteTypes.Bet({
            player: msg.sender,
            amount: amount,
            betType: betType,
            numbers: numbers,
            timestamp: block.timestamp,
            settled: false,
            won: false,
            payout: 0
        });

        if (rounds[currentRoundId].timestamp == 0) {
            rounds[currentRoundId] = RouletteTypes.Round({
                roundId: currentRoundId,
                requestId: 0,
                winningNumber: 255,
                winningColor: RouletteTypes.Color.GREEN,
                timestamp: block.timestamp,
                completed: false,
                totalBets: 0,
                totalPayout: 0
            });
        }
        
        roundBets[currentRoundId].push(betIdCounter);
        rounds[currentRoundId].totalBets += amount;

        playerStats[msg.sender].totalBets++;
        playerStats[msg.sender].totalWagered += amount;
        playerStats[msg.sender].lastPlayedTimestamp = block.timestamp;

        emit BetPlaced(currentRoundId, betIdCounter, msg.sender, betType, amount);
    }

    /**
     * @notice Request spin - changes state to CALCULATING and generates winning number
     * @dev In Phase 1, uses pseudo-random. Phase 2 will use Chainlink VRF
     * After settling bets, automatically returns to OPEN state
     */
    function spin() external onlyOwner nonReentrant whenNotPaused {
        if (state != RouletteTypes.RouletteState.OPEN) revert AlreadyCalculating();
        
        if (lastSpinTimestamp > 0) {
            uint256 timeSinceLastSpin = block.timestamp - lastSpinTimestamp;
            if (timeSinceLastSpin < spinDelay) {
                revert SpinDelayNotMet(spinDelay - timeSinceLastSpin);
            }
        }
        
        if (roundBets[currentRoundId].length == 0) revert NoActiveBets();

        state = RouletteTypes.RouletteState.CALCULATING;
        emit StateChanged(RouletteTypes.RouletteState.CALCULATING);
        emit SpinRequested(currentRoundId, block.timestamp);

        RouletteTypes.Round storage round = rounds[currentRoundId];

        uint8 winningNumber = uint8(
            uint256(
                keccak256(
                    abi.encodePacked(
                        block.timestamp,
                        block.prevrandao,
                        msg.sender,
                        currentRoundId,
                        blockhash(block.number - 1)
                    )
                )
            ) % 37
        );

        round.winningNumber = winningNumber;
        round.winningColor = RouletteTypes.getNumberColor(winningNumber);
        round.completed = true;

        _settleBets(currentRoundId, winningNumber);

        emit SpinCompleted(
            currentRoundId,
            winningNumber,
            round.winningColor,
            round.totalPayout
        );

        lastSpinTimestamp = block.timestamp;

        currentRoundId++;
        state = RouletteTypes.RouletteState.OPEN;
        emit StateChanged(RouletteTypes.RouletteState.OPEN);
    }

    /**
     * @notice Update minimum bet
     * @param _minBet New minimum bet
     */
    function setMinBet(uint256 _minBet) external onlyOwner {
        uint256 oldMinBet = minBet;
        minBet = _minBet;
        emit MinBetUpdated(oldMinBet, _minBet);
    }

    /**
     * @notice Update maximum bet
     * @param _maxBet New maximum bet
     */
    function setMaxBet(uint256 _maxBet) external onlyOwner {
        uint256 oldMaxBet = maxBet;
        maxBet = _maxBet;
        emit MaxBetUpdated(oldMaxBet, _maxBet);
    }

    /**
     * @notice Update house edge
     * @param _houseEdge New house edge in basis points
     */
    function setHouseEdge(uint256 _houseEdge) external onlyOwner {
        uint256 oldHouseEdge = houseEdge;
        houseEdge = _houseEdge;
        emit HouseEdgeUpdated(oldHouseEdge, _houseEdge);
    }

    /**
     * @notice Update spin delay
     * @param _spinDelay New spin delay in seconds
     */
    function setSpinDelay(uint256 _spinDelay) external onlyOwner {
        uint256 oldDelay = spinDelay;
        spinDelay = _spinDelay;
        emit SpinDelayUpdated(oldDelay, _spinDelay);
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Emergency function to force state to CALCULATING (stops betting)
     */
    function emergencyStopBetting() external onlyOwner {
        state = RouletteTypes.RouletteState.CALCULATING;
        emit StateChanged(RouletteTypes.RouletteState.CALCULATING);
    }

    /**
     * @notice Emergency function to force state to OPEN (resumes betting)
     */
    function emergencyResumeBetting() external onlyOwner {
        state = RouletteTypes.RouletteState.OPEN;
        emit StateChanged(RouletteTypes.RouletteState.OPEN);
    }

    // Internal functions
    /**
     * @notice Settle all bets for a round
     * @param roundId Round ID to settle
     * @param winningNumber The winning number
     */
    function _settleBets(uint256 roundId, uint8 winningNumber) internal {
        uint256[] memory betIds = roundBets[roundId];
        uint256 totalPayout = 0;

        for (uint256 i = 0; i < betIds.length; i++) {
            uint256 betId = betIds[i];
            RouletteTypes.Bet storage bet = bets[betId];

            if (bet.settled) continue;

            bool won = RouletteTypes.checkWin(bet.betType, bet.numbers, winningNumber);
            bet.won = won;
            bet.settled = true;

            if (won) {
                uint256 multiplier = RouletteTypes.getPayoutMultiplier(bet.betType);
                uint256 payout = bet.amount + (bet.amount * multiplier);
                bet.payout = payout;
                totalPayout += payout;

                bettingToken.mint(bet.player, payout);

                playerStats[bet.player].totalWon += payout;

                emit BetSettled(betId, bet.player, true, payout);
            } else {
                playerStats[bet.player].totalLost += bet.amount;
                emit BetSettled(betId, bet.player, false, 0);
            }
        }

        rounds[roundId].totalPayout = totalPayout;
    }

    // View functions
    /**
     * @notice Get all bet IDs for a round
     * @param roundId Round ID
     * @return Array of bet IDs
     */
    function getRoundBets(uint256 roundId) external view returns (uint256[] memory) {
        return roundBets[roundId];
    }

    /**
     * @notice Get bet details
     * @param betId Bet ID
     * @return Bet struct
     */
    function getBet(uint256 betId) external view returns (RouletteTypes.Bet memory) {
        return bets[betId];
    }

    /**
     * @notice Get player statistics
     * @param player Player address
     * @return PlayerStats struct
     */
    function getPlayerStats(address player) external view returns (RouletteTypes.PlayerStats memory) {
        return playerStats[player];
    }

    /**
     * @notice Get round details
     * @param roundId Round ID
     * @return Round struct
     */
    function getRound(uint256 roundId) external view returns (RouletteTypes.Round memory) {
        return rounds[roundId];
    }

    /**
     * @notice Get current state of the roulette
     * @return Current RouletteState
     */
    function getState() external view returns (RouletteTypes.RouletteState) {
        return state;
    }
}
