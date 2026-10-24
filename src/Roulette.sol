// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {RouletteVault} from "src/RouletteVault.sol";
import {IRouletteLiquidity} from "src/interfaces/IRouletteLiquidity.sol";
import {RouletteTypes} from "src/libraries/RouletteTypes.sol";

/**
 * @title Roulette
 * @notice Main contract for the decentralized roulette game with Chainlink VRF
 * @dev Custodies all player USDC: players deposit USDC for credits (1:1) and bet with credits.
 *      The vault only holds LP liquidity. At settlement, one net USDC transfer per round moves
 *      the house's winnings to the vault, or pulls the players' winnings from it.
 *      Implements European roulette (0-36) with Chainlink VRF V2.5.
 *      Owner functionality (two-step transfer) comes from VRFConsumerBaseV2Plus.
 * @custom:security-contact TODO
 */
contract Roulette is ReentrancyGuardTransient, Pausable, VRFConsumerBaseV2Plus, IRouletteLiquidity {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    // Chainlink VRF V2.5
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;
    uint256 private immutable i_subscriptionId;
    bytes32 private immutable i_gasLane;
    uint32 private immutable i_callbackGasLimit;
    bool private immutable i_nativePayment; // true = pay with ETH, false = pay with LINK

    /// @notice Max bets per round, so a round with every bet winning settles within the callback gas limit
    uint256 public constant MAX_BETS_PER_ROUND = 75;
    uint256 private constant BPS = 10_000;

    RouletteVault public immutable vault;
    IERC20 public immutable usdc;

    // Roulette state
    RouletteTypes.RouletteState public state;
    uint256 public minBet;
    uint256 public maxBet;
    uint256 public houseEdge;
    uint256 public currentRoundId;
    uint256 public betIdCounter;
    uint256 public spinDelay;
    uint256 public lastSpinTimestamp;
    uint256 public spinRequestedAt;
    /// @notice Max net worst-case payout of a round, in bps of vault assets
    uint256 public maxExposureBps;
    /// @notice Time after a spin request before the owner can refund the round
    uint256 public vrfTimeout;
    /// @notice USDC owed by the vault after a round it could not fully cover
    uint256 public deficit;

    // Player credits (1:1 with USDC held by this contract)
    mapping(address => uint256) public credits;
    uint256 public totalCredits;

    // House statistics
    uint256 public totalWagered;
    uint256 public totalPaidOut;
    int256 public houseNetPnl;

    mapping(uint256 requestId => uint256 roundId) private s_requestIdToRoundId;
    mapping(uint256 => RouletteTypes.Round) private s_rounds;
    mapping(uint256 => RouletteTypes.Bet) private s_bets;
    mapping(address => RouletteTypes.PlayerStats) private s_playerStats;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event StateChanged(RouletteTypes.RouletteState indexed newState);
    event CreditsDeposited(address indexed player, uint256 amount);
    event CreditsWithdrawn(address indexed player, uint256 amount);
    event BetPlaced(
        uint256 indexed roundId,
        uint256 indexed betId,
        address indexed player,
        RouletteTypes.BetType betType,
        uint256 amount
    );
    event SpinRequested(uint256 indexed roundId, uint256 timestamp);
    event BetWon(uint256 indexed betId, address indexed player, uint256 payout);
    event SpinCompleted(
        uint256 indexed roundId, uint8 winningNumber, RouletteTypes.Color winningColor, uint256 totalPayout
    );
    event RoundSettled(uint256 indexed roundId, uint256 totalBets, uint256 totalPayout, int256 netToPlayers);
    event DeficitRecorded(uint256 indexed roundId, uint256 deficit);
    event DeficitCovered(uint256 amount, uint256 remaining);
    event RoundRefunded(uint256 indexed roundId);
    event MinBetUpdated(uint256 oldMinBet, uint256 newMinBet);
    event MaxBetUpdated(uint256 oldMaxBet, uint256 newMaxBet);
    event HouseEdgeUpdated(uint256 oldHouseEdge, uint256 newHouseEdge);
    event SpinDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event MaxExposureBpsUpdated(uint256 oldBps, uint256 newBps);
    event VrfTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error Roulette__RouletteNotOpen();
    error Roulette__InvalidBetAmount();
    error Roulette__InvalidNumbers();
    error Roulette__NoActiveBets();
    error Roulette__AlreadyCalculating();
    error Roulette__SpinDelayNotMet(uint256 timeRemaining);
    error Roulette__InvalidRequestId();
    error Roulette__InsufficientCredits();
    error Roulette__InvalidAmount();
    error Roulette__InvalidBps();
    error Roulette__RoundFull();
    error Roulette__ExposureLimitExceeded();
    error Roulette__InsufficientRouletteBalance();
    error Roulette__NoDeficit();
    error Roulette__NothingToCover();
    error Roulette__NotCalculating();
    error Roulette__VrfTimeoutNotReached(uint256 timeRemaining);
    error Roulette__DeficitOpen();
    error Roulette__SpinPending();

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
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
     * @param _maxExposureBps Max net worst-case payout of a round, in bps of vault assets
     * @param _vrfTimeout Time after a spin request before the owner can refund the round
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
        uint256 _spinDelay,
        uint256 _maxExposureBps,
        uint256 _vrfTimeout
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        if (_maxExposureBps > BPS) revert Roulette__InvalidBps();
        i_subscriptionId = _subscriptionId;
        i_gasLane = _gasLane;
        i_callbackGasLimit = _callbackGasLimit;
        i_nativePayment = _nativePayment;

        vault = RouletteVault(_vault);
        usdc = IERC20(RouletteVault(_vault).asset());
        minBet = _minBet;
        maxBet = _maxBet;
        houseEdge = _houseEdge;
        spinDelay = _spinDelay;
        maxExposureBps = _maxExposureBps;
        vrfTimeout = _vrfTimeout;
        currentRoundId = 1;
    }

    /*//////////////////////////////////////////////////////////////
                   USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Deposit USDC to receive credits for betting (1:1)
     * @param amount Amount of USDC to deposit
     */
    function depositCredits(uint256 amount) external nonReentrant {
        if (amount == 0) revert Roulette__InvalidAmount();

        credits[msg.sender] += amount;
        totalCredits += amount;
        emit CreditsDeposited(msg.sender, amount);

        usdc.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraw credits back to USDC
     * @dev Allowed in every state. During a deficit, withdrawals are first come, first served:
     *      once this contract's balance runs out, they revert until the deficit is covered.
     * @param amount Amount of credits to withdraw
     */
    function withdrawCredits(uint256 amount) external nonReentrant {
        if (amount == 0) revert Roulette__InvalidAmount();
        if (credits[msg.sender] < amount) revert Roulette__InsufficientCredits();
        if (state == RouletteTypes.RouletteState.DEFICIT && usdc.balanceOf(address(this)) < amount) {
            revert Roulette__InsufficientRouletteBalance();
        }

        credits[msg.sender] -= amount;
        totalCredits -= amount;
        emit CreditsWithdrawn(msg.sender, amount);

        usdc.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Place a bet using credits
     * @param betType Type of bet
     * @param numbers Numbers to bet on (depends on bet type)
     * @param amount Amount to bet
     */
    function placeBet(RouletteTypes.BetType betType, uint8[] calldata numbers, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        uint8[] memory nums = numbers;
        if (!RouletteTypes.validateBet(betType, nums)) revert Roulette__InvalidNumbers();
        uint40 numbersMask = RouletteTypes.toNumbersMask(betType, nums);
        if (state != RouletteTypes.RouletteState.OPEN) revert Roulette__RouletteNotOpen();
        if (amount < minBet || amount > maxBet) revert Roulette__InvalidBetAmount();
        uint256 playerCredits = credits[msg.sender];
        if (playerCredits < amount) revert Roulette__InsufficientCredits();

        uint256 roundId = currentRoundId;
        uint256 betId = ++betIdCounter;
        _addBetToRound(roundId, betId, betType, amount);

        // Debit credits; the USDC stays here as the round's stake
        credits[msg.sender] = playerCredits - amount;
        totalCredits -= amount;

        s_bets[betId] = RouletteTypes.Bet({
            player: msg.sender, betType: betType, numbersMask: numbersMask, amount: amount.toUint48()
        });
        _recordPlayerBet(roundId, amount);

        emit BetPlaced(roundId, betId, msg.sender, betType, amount);
    }

    /**
     * @notice Request spin - changes state to CALCULATING and requests random number from Chainlink VRF
     * @dev The winning number is determined in the fulfillRandomWords callback
     */
    function spin() external nonReentrant onlyOwner whenNotPaused {
        if (state != RouletteTypes.RouletteState.OPEN) revert Roulette__AlreadyCalculating();

        uint256 lastSpin = lastSpinTimestamp;
        if (lastSpin > 0) {
            uint256 timeSinceLastSpin = block.timestamp - lastSpin;
            if (timeSinceLastSpin < spinDelay) revert Roulette__SpinDelayNotMet(spinDelay - timeSinceLastSpin);
        }

        uint256 roundId = currentRoundId;
        if (s_rounds[roundId].firstBetId == 0) revert Roulette__NoActiveBets();

        _setState(RouletteTypes.RouletteState.CALCULATING);
        spinRequestedAt = block.timestamp;

        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: i_gasLane,
                subId: i_subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: i_callbackGasLimit,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: i_nativePayment}))
            })
        );

        s_requestIdToRoundId[requestId] = roundId;
        s_rounds[roundId].requestId = requestId;

        emit SpinRequested(roundId, block.timestamp);
    }

    /**
     * @notice Pull USDC from the vault to pay back an open deficit
     * @dev Permissionless. Fund the vault with a plain USDC transfer first.
     */
    function coverDeficit() external nonReentrant {
        if (state != RouletteTypes.RouletteState.DEFICIT) revert Roulette__NoDeficit();

        uint256 owed = deficit;
        uint256 amount = usdc.balanceOf(address(vault));
        if (amount == 0) revert Roulette__NothingToCover();
        if (amount > owed) amount = owed;

        owed -= amount;
        deficit = owed;
        if (owed == 0) _setState(RouletteTypes.RouletteState.OPEN);
        emit DeficitCovered(amount, owed);

        vault.fundPayout(amount);
    }

    /**
     * @notice Refund the current round when Chainlink VRF never answered
     * @dev Re-credits every stake and rolls back the bets' stats. A late VRF answer for the
     *      refunded round reverts with InvalidRequestId.
     */
    function refundRound() external nonReentrant onlyOwner {
        if (state != RouletteTypes.RouletteState.CALCULATING) revert Roulette__NotCalculating();
        uint256 elapsed = block.timestamp - spinRequestedAt;
        if (elapsed < vrfTimeout) revert Roulette__VrfTimeoutNotReached(vrfTimeout - elapsed);

        uint256 roundId = currentRoundId;
        RouletteTypes.Round storage round = s_rounds[roundId];

        uint256 lastBetId = round.lastBetId;
        for (uint256 betId = round.firstBetId; betId != 0 && betId <= lastBetId; ++betId) {
            RouletteTypes.Bet memory bet = s_bets[betId];
            credits[bet.player] += bet.amount;

            RouletteTypes.PlayerStats storage stats = s_playerStats[bet.player];
            stats.totalBets -= 1;
            stats.totalWagered -= bet.amount;
            stats.lastRoundWagered -= bet.amount;
        }
        totalCredits += round.totalBets;

        delete s_requestIdToRoundId[round.requestId];
        round.completed = true;
        round.refunded = true;

        currentRoundId = roundId + 1;
        _setState(RouletteTypes.RouletteState.OPEN);
        emit RoundRefunded(roundId);
    }

    /// @notice Update minimum bet
    function setMinBet(uint256 _minBet) external onlyOwner {
        emit MinBetUpdated(minBet, _minBet);
        minBet = _minBet;
    }

    /// @notice Update maximum bet
    function setMaxBet(uint256 _maxBet) external onlyOwner {
        emit MaxBetUpdated(maxBet, _maxBet);
        maxBet = _maxBet;
    }

    /// @notice Update house edge (informational, in basis points)
    function setHouseEdge(uint256 _houseEdge) external onlyOwner {
        emit HouseEdgeUpdated(houseEdge, _houseEdge);
        houseEdge = _houseEdge;
    }

    /// @notice Update spin delay
    function setSpinDelay(uint256 _spinDelay) external onlyOwner {
        emit SpinDelayUpdated(spinDelay, _spinDelay);
        spinDelay = _spinDelay;
    }

    /// @notice Update the max net worst-case payout of a round, in bps of vault assets
    function setMaxExposureBps(uint256 _maxExposureBps) external onlyOwner {
        if (_maxExposureBps > BPS) revert Roulette__InvalidBps();
        emit MaxExposureBpsUpdated(maxExposureBps, _maxExposureBps);
        maxExposureBps = _maxExposureBps;
    }

    /// @notice Update the time after a spin request before the owner can refund the round
    function setVrfTimeout(uint256 _vrfTimeout) external onlyOwner {
        emit VrfTimeoutUpdated(vrfTimeout, _vrfTimeout);
        vrfTimeout = _vrfTimeout;
    }

    /// @notice Pause the contract
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Emergency function to force state to CALCULATING (stops betting)
    function emergencyStopBetting() external onlyOwner {
        if (state == RouletteTypes.RouletteState.DEFICIT) revert Roulette__DeficitOpen();
        _setState(RouletteTypes.RouletteState.CALCULATING);
    }

    /**
     * @notice Emergency function to force state to OPEN (resumes betting)
     * @dev Not allowed while a VRF answer is pending: the result would be public in the mempool
     *      while bets are open. Use refundRound for a stuck spin.
     */
    function emergencyResumeBetting() external onlyOwner {
        if (state == RouletteTypes.RouletteState.DEFICIT) revert Roulette__DeficitOpen();
        if (s_rounds[currentRoundId].requestId != 0) revert Roulette__SpinPending();
        _setState(RouletteTypes.RouletteState.OPEN);
    }

    /*//////////////////////////////////////////////////////////////
                     USER-FACING READ-ONLY FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @inheritdoc IRouletteLiquidity
    function lpLocked() external view returns (bool) {
        return state != RouletteTypes.RouletteState.OPEN;
    }

    /// @inheritdoc IRouletteLiquidity
    function reservedLiquidity() external view returns (uint256 reserved) {
        RouletteTypes.Round storage round = s_rounds[currentRoundId];
        reserved = round.maxExposure - round.totalBets;
    }

    /// @notice Get all bet IDs for a round
    function getRoundBets(uint256 roundId) external view returns (uint256[] memory betIds) {
        RouletteTypes.Round storage round = s_rounds[roundId];
        uint256 first = round.firstBetId;
        if (first == 0) return betIds;
        betIds = new uint256[](round.lastBetId - first + 1);
        for (uint256 i; i < betIds.length; ++i) {
            betIds[i] = first + i;
        }
    }

    /// @notice Get bet details
    function getBet(uint256 betId) external view returns (RouletteTypes.Bet memory) {
        return s_bets[betId];
    }

    /**
     * @notice Get a bet's result, derived from its round's winning number
     * @return settled True once the round completed (and was not refunded)
     * @return won Whether the bet won
     * @return payout Stake + winnings if the bet won
     */
    function getBetResult(uint256 betId, uint256 roundId)
        external
        view
        returns (bool settled, bool won, uint256 payout)
    {
        RouletteTypes.Round storage round = s_rounds[roundId];
        if (betId < round.firstBetId || betId > round.lastBetId) return (false, false, 0);
        settled = round.completed && !round.refunded;
        if (!settled) return (false, false, 0);

        RouletteTypes.Bet memory bet = s_bets[betId];
        won = RouletteTypes.checkWin(bet.numbersMask, round.winningNumber);
        if (won) payout = uint256(bet.amount) * (RouletteTypes.getPayoutMultiplier(bet.betType) + 1);
    }

    /// @notice Get player statistics. totalLost excludes stakes of the round in progress.
    function getPlayerStats(address player) external view returns (RouletteTypes.PlayerStatsView memory view_) {
        RouletteTypes.PlayerStats storage stats = s_playerStats[player];
        uint256 pending = s_rounds[stats.lastRoundId].completed ? 0 : stats.lastRoundWagered;

        view_.totalBets = stats.totalBets;
        view_.totalWagered = stats.totalWagered;
        view_.totalWon = stats.totalWon;
        view_.totalLost = stats.totalWagered - stats.totalWonStakes - pending;
        view_.lastPlayedTimestamp = stats.lastPlayedTimestamp;
    }

    /// @notice Get house statistics
    function getHouseStats() external view returns (uint256 wagered, uint256 paidOut, int256 netPnl) {
        return (totalWagered, totalPaidOut, houseNetPnl);
    }

    /// @notice Get round details
    function getRound(uint256 roundId) external view returns (RouletteTypes.Round memory) {
        return s_rounds[roundId];
    }

    /// @notice Get current state of the roulette
    function getState() external view returns (RouletteTypes.RouletteState) {
        return state;
    }

    /// @notice Get VRF configuration
    function getVrfConfig()
        external
        view
        returns (
            address vrfCoordinator,
            uint256 subscriptionId,
            bytes32 gasLane,
            uint32 callbackGasLimit,
            bool nativePayment
        )
    {
        return (address(s_vrfCoordinator), i_subscriptionId, i_gasLane, i_callbackGasLimit, i_nativePayment);
    }

    /// @notice Get round ID from VRF request ID
    function getRequestIdToRoundId(uint256 requestId) external view returns (uint256) {
        return s_requestIdToRoundId[requestId];
    }

    /// @notice Get player's credit balance
    function getCredits(address player) external view returns (uint256) {
        return credits[player];
    }

    /// @notice Get total credits in circulation
    function getTotalCredits() external view returns (uint256) {
        return totalCredits;
    }

    /*//////////////////////////////////////////////////////////////
                   INTERNAL STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @dev Adds a bet to the round: bet id range, bet count cap and exposure limit
     *      (the round's net worst case must stay within maxExposureBps of vault assets).
     */
    function _addBetToRound(uint256 roundId, uint256 betId, RouletteTypes.BetType betType, uint256 amount)
        internal
    {
        RouletteTypes.Round storage round = s_rounds[roundId];

        if (round.firstBetId == 0) {
            round.firstBetId = betId.toUint64();
            round.timestamp = uint64(block.timestamp);
            round.winningNumber = type(uint8).max;
        } else if (betId - round.firstBetId >= MAX_BETS_PER_ROUND) {
            revert Roulette__RoundFull();
        }
        // forge-lint: disable-next-line(unsafe-typecast) bet ids can't reach 2^64
        round.lastBetId = uint64(betId);

        uint256 roundTotalBets = round.totalBets + amount;
        uint256 roundMaxExposure = round.maxExposure + amount * (RouletteTypes.getPayoutMultiplier(betType) + 1);
        if ((roundMaxExposure - roundTotalBets) * BPS > vault.totalAssets() * maxExposureBps) {
            revert Roulette__ExposureLimitExceeded();
        }
        round.totalBets = roundTotalBets.toUint128();
        round.maxExposure = roundMaxExposure;
    }

    /// @dev Updates the bettor's stats at bet time (two slots; settlement only touches winners)
    function _recordPlayerBet(uint256 roundId, uint256 amount) internal {
        RouletteTypes.PlayerStats storage stats = s_playerStats[msg.sender];
        if (stats.lastRoundId != roundId) {
            // forge-lint: disable-next-line(unsafe-typecast) round ids can't reach 2^64
            stats.lastRoundId = uint64(roundId);
            stats.lastRoundWagered = 0;
        }
        // forge-lint: disable-next-line(unsafe-typecast) amount fits in uint48 (checked when storing the bet)
        stats.lastRoundWagered += uint120(amount);
        stats.totalBets += 1;
        stats.lastPlayedTimestamp = uint40(block.timestamp);
        stats.totalWagered += amount;
    }

    /**
     * @notice Callback called by Chainlink VRF with the random number
     * @dev Must not revert for funding reasons: Chainlink does not retry. Settles every bet of the
     *      round in one loop, then moves the round's net amount between Roulette and the vault.
     */
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        uint256 roundId = s_requestIdToRoundId[requestId];
        if (roundId == 0) revert Roulette__InvalidRequestId();
        delete s_requestIdToRoundId[requestId];

        RouletteTypes.Round storage round = s_rounds[roundId];
        uint8 winningNumber = uint8(randomWords[0] % RouletteTypes.WHEEL_SIZE);
        RouletteTypes.Color winningColor = RouletteTypes.getNumberColor(winningNumber);

        uint256 totalPayout;
        uint256 lastBetId = round.lastBetId;
        for (uint256 betId = round.firstBetId; betId <= lastBetId; ++betId) {
            RouletteTypes.Bet memory bet = s_bets[betId];
            if (!RouletteTypes.checkWin(bet.numbersMask, winningNumber)) continue;

            uint256 winnings = uint256(bet.amount) * RouletteTypes.getPayoutMultiplier(bet.betType);
            uint256 payout = bet.amount + winnings;
            totalPayout += payout;
            credits[bet.player] += payout;

            RouletteTypes.PlayerStats storage stats = s_playerStats[bet.player];
            // forge-lint: disable-next-line(unsafe-typecast) winnings <= uint48 amount * 35
            stats.totalWon += uint128(winnings);
            stats.totalWonStakes += bet.amount;

            emit BetWon(betId, bet.player, payout);
        }

        uint256 roundTotalBets = round.totalBets;
        // forge-lint: disable-next-line(unsafe-typecast) both are bounded by uint128 round totals
        int256 netToPlayers = int256(totalPayout) - int256(roundTotalBets);

        totalCredits += totalPayout;
        totalWagered += roundTotalBets;
        totalPaidOut += totalPayout;
        houseNetPnl -= netToPlayers;

        round.winningNumber = winningNumber;
        round.winningColor = winningColor;
        round.completed = true;
        // forge-lint: disable-next-line(unsafe-typecast) payout <= round maxExposure, bounded by MAX_BETS_PER_ROUND uint48 bets
        round.totalPayout = uint128(totalPayout);

        lastSpinTimestamp = block.timestamp;
        currentRoundId = roundId + 1;

        emit SpinCompleted(roundId, winningNumber, winningColor, totalPayout);
        emit RoundSettled(roundId, roundTotalBets, totalPayout, netToPlayers);

        _settleWithVault(roundId, netToPlayers);
    }

    /**
     * @dev Moves the round's net amount between Roulette and the vault. If the vault can't cover
     *      the players' net winnings, pulls what it has and records the rest as a deficit.
     */
    function _settleWithVault(uint256 roundId, int256 netToPlayers) internal {
        if (netToPlayers < 0) {
            _setState(RouletteTypes.RouletteState.OPEN);
            // forge-lint: disable-next-line(unsafe-typecast) netToPlayers < 0
            usdc.safeTransfer(address(vault), uint256(-netToPlayers));
            return;
        }
        if (netToPlayers == 0) {
            _setState(RouletteTypes.RouletteState.OPEN);
            return;
        }

        // forge-lint: disable-next-line(unsafe-typecast) netToPlayers > 0
        uint256 owed = uint256(netToPlayers);
        uint256 available = usdc.balanceOf(address(vault));
        if (available >= owed) {
            _setState(RouletteTypes.RouletteState.OPEN);
            vault.fundPayout(owed);
            return;
        }

        deficit = owed - available;
        _setState(RouletteTypes.RouletteState.DEFICIT);
        emit DeficitRecorded(roundId, owed - available);
        if (available > 0) vault.fundPayout(available);
    }

    function _setState(RouletteTypes.RouletteState newState) internal {
        state = newState;
        emit StateChanged(newState);
    }
}
