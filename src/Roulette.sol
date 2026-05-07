// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Imports
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {RouletteVault} from "./RouletteVault.sol";
import {RouletteTypes} from "./libraries/RouletteTypes.sol";

/**
 * @title Roulette
 * @notice Main contract for the decentralized roulette game with Chainlink VRF
 * @dev Players use credits (1:1 with USDC) for betting, vault holds all USDC
 * Vault manages USDC deposits/withdrawals and credits via addCredits/removeCredits
 * Implements European roulette (0-36)
 * Bets are always open except when calculating results (CALCULATING state)
 * Uses Chainlink VRF V2.5 for verifiable random number generation
 * Inherits owner functionality from VRFConsumerBaseV2Plus
 */
contract Roulette is ReentrancyGuard, Pausable, VRFConsumerBaseV2Plus {
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
    error InvalidRequestId();
    error InsufficientCredits();
    error InsufficientVaultLiquidity();
    error InvalidAmount();
    error OnlyVault();

    // State variables
    // Chainlink VRF V2.5
    uint256 private immutable i_subscriptionId;
    bytes32 private immutable i_gasLane;
    uint32 private immutable i_callbackGasLimit;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;
    bool private immutable i_nativePayment; // true = pay with ETH, false = pay with LINK
    
    // Mapping from VRF requestId to roundId
    mapping(uint256 => uint256) private s_requestIdToRoundId;
    
    // Roulette state
    RouletteVault public immutable vault;
    RouletteTypes.RouletteState public state;
    uint256 public minBet;
    uint256 public maxBet;
    uint256 public houseEdge;
    uint256 public currentRoundId;
    uint256 public betIdCounter;
    uint256 public spinDelay;
    uint256 public lastSpinTimestamp;
    
    // Player credits system (1:1 with USDC)
    mapping(address => uint256) public credits;
    uint256 public totalCredits;
    
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
     * @param _vrfCoordinator Address of the Chainlink VRF Coordinator V2.5
     * @param _subscriptionId Chainlink VRF subscription ID
     * @param _gasLane Chainlink VRF gas lane (key hash)
     * @param _callbackGasLimit Gas limit for the callback
     * @param _nativePayment Whether to pay for VRF with native ETH (true) or LINK (false)
     * @param _vault Address of the RouletteVault
     * @param _minBet Minimum bet amount
     * @param _maxBet Maximum bet amount
     * @param _houseEdge House edge in basis points (270 = 2.7%)
     * @param _spinDelay Minimum delay between spins in seconds
     */
    constructor(
        address _vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _gasLane,
        uint32 _callbackGasLimit,
        bool _nativePayment,
        address _vault,
        uint256 _minBet,
        uint256 _maxBet,
        uint256 _houseEdge,
        uint256 _spinDelay
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        i_subscriptionId = _subscriptionId;
        i_gasLane = _gasLane;
        i_callbackGasLimit = _callbackGasLimit;
        i_nativePayment = _nativePayment;

        vault = RouletteVault(_vault);
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
     * @notice Add credits to a player (called by Vault)
     * @dev Only callable by the vault when player deposits USDC
     * @param player Player address
     * @param amount Amount of credits to add
     */
    function addCredits(address player, uint256 amount) external {
        if (msg.sender != address(vault)) revert OnlyVault();

        credits[player] += amount;
        totalCredits += amount;
    }

    /**
     * @notice Remove credits from a player (called by Vault)
     * @dev Only callable by the vault when player withdraws USDC
     * @param player Player address
     * @param amount Amount of credits to remove
     */
    function removeCredits(address player, uint256 amount) external {
        if (msg.sender != address(vault)) revert OnlyVault();
        if (credits[player] < amount) revert InsufficientCredits();
        
        credits[player] -= amount;
        totalCredits -= amount;
    }

    /**
     * @notice Place a bet using credits
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
        if (credits[msg.sender] < amount) revert InsufficientCredits();

        // Burn credits from player
        credits[msg.sender] -= amount;
        totalCredits -= amount;

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
     * @notice Request spin - changes state to CALCULATING and requests random number from Chainlink VRF
     * @dev Uses Chainlink VRF V2.5 for verifiable random number generation
     * The winning number will be determined in fulfillRandomWords callback
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

        // Change state to CALCULATING
        state = RouletteTypes.RouletteState.CALCULATING;
        emit StateChanged(RouletteTypes.RouletteState.CALCULATING);

        // Request random number from Chainlink VRF V2.5
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: i_gasLane,
                subId: i_subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: i_callbackGasLimit,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: i_nativePayment})
                )
            })
        );

        // Store mapping of requestId to roundId
        s_requestIdToRoundId[requestId] = currentRoundId;
        rounds[currentRoundId].requestId = requestId;

        emit SpinRequested(currentRoundId, block.timestamp);
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
     * @notice Callback function called by Chainlink VRF with the random number
     * @param requestId The VRF request ID
     * @param randomWords Array of random numbers (we only use the first one)
     */
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        uint256 roundId = s_requestIdToRoundId[requestId];
        if (roundId == 0) revert InvalidRequestId();

        RouletteTypes.Round storage round = rounds[roundId];
        
        // Convert random number to roulette number (0-36)
        uint8 winningNumber = uint8(randomWords[0] % 37);

        round.winningNumber = winningNumber;
        round.winningColor = RouletteTypes.getNumberColor(winningNumber);
        round.completed = true;

        _settleBets(roundId, winningNumber);

        emit SpinCompleted(
            roundId,
            winningNumber,
            round.winningColor,
            round.totalPayout
        );

        lastSpinTimestamp = block.timestamp;

        // Move to next round and reopen betting
        currentRoundId++;
        state = RouletteTypes.RouletteState.OPEN;
        emit StateChanged(RouletteTypes.RouletteState.OPEN);
    }

    /**
     * @notice Settle all bets for a round
     * @param roundId Round ID to settle
     * @param winningNumber The winning number
     */
    function _settleBets(uint256 roundId, uint8 winningNumber) internal {
        uint256[] memory betIds = roundBets[roundId];
        uint256 totalPayout = 0;
        uint256 totalLoss = 0;

        for (uint256 i = 0; i < betIds.length; i++) {
            uint256 betId = betIds[i];
            RouletteTypes.Bet storage bet = bets[betId];

            if (bet.settled) continue;

            bool won = RouletteTypes.checkWin(bet.betType, bet.numbers, winningNumber);
            bet.won = won;
            bet.settled = true;

            if (won) {
                uint256 multiplier = RouletteTypes.getPayoutMultiplier(bet.betType);
                uint256 winnings = bet.amount * multiplier;
                uint256 payout = bet.amount + winnings;
                bet.payout = payout;
                totalPayout += payout;

                // Check vault has liquidity and record payout stats
                vault.payout(bet.player, payout);

                // Credit player with winnings (USDC stays in vault)
                credits[bet.player] += payout;
                totalCredits += payout;

                // Track only the profit (winnings), not the returned bet
                playerStats[bet.player].totalWon += winnings;

                emit BetSettled(betId, bet.player, true, payout);
            } else {
                // Bet was lost, credits were already burned in placeBet()
                totalLoss += bet.amount;
                
                playerStats[bet.player].totalLost += bet.amount;
                emit BetSettled(betId, bet.player, false, 0);
            }
        }

        rounds[roundId].totalPayout = totalPayout;
        
        // Record stats in vault
        vault.recordBet(rounds[roundId].totalBets);
        
        if (totalPayout > rounds[roundId].totalBets) {
            // Vault lost money
            uint256 loss = totalPayout - rounds[roundId].totalBets;
            vault.recordLoss(loss);
        } else {
            // Vault profited
            vault.recordProfit(totalLoss);
        }
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

    /**
     * @notice Get VRF configuration
     * @return vrfCoordinator Address of VRF Coordinator
     * @return subscriptionId Subscription ID
     * @return gasLane Gas lane (key hash)
     * @return callbackGasLimit Callback gas limit
     * @return nativePayment Whether paying with native ETH
     */
    function getVrfConfig()
        external
        view
        returns (address vrfCoordinator, uint256 subscriptionId, bytes32 gasLane, uint32 callbackGasLimit, bool nativePayment)
    {
        return (address(s_vrfCoordinator), i_subscriptionId, i_gasLane, i_callbackGasLimit, i_nativePayment);
    }

    /**
     * @notice Get round ID from VRF request ID
     * @param requestId VRF request ID
     * @return Round ID
     */
    function getRequestIdToRoundId(uint256 requestId) external view returns (uint256) {
        return s_requestIdToRoundId[requestId];
    }

    /**
     * @notice Get player's credit balance
     * @param player Player address
     * @return Credit balance
     */
    function getCredits(address player) external view returns (uint256) {
        return credits[player];
    }

    /**
     * @notice Get total credits in circulation
     * @return Total credits
     */
    function getTotalCredits() external view returns (uint256) {
        return totalCredits;
    }
}
