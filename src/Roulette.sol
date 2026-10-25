// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
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
 *      Does not inherit VRFConsumerBaseV2Plus: its owner-callable setCoordinator would let the owner
 *      make the real coordinator's callback revert, then refund a round whose result they disliked.
 *      The coordinator is fixed at deploy time and rawFulfillRandomWords is implemented here.
 * @custom:security-contact https://github.com/LucasConesaFever/DRoulette/issues
 */
contract Roulette is ReentrancyGuardTransient, Pausable, Ownable2Step, IRouletteLiquidity {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    // Chainlink VRF V2.5
    uint16 private constant REQUEST_CONFIRMATIONS = 3; // {block}
    uint32 private constant NUM_WORDS = 1; // {count}
    /// @dev Fixed coordinator: the only address whose callback can settle a round
    IVRFCoordinatorV2Plus private immutable i_vrfCoordinator;
    uint256 private immutable i_subscriptionId;
    bytes32 private immutable i_gasLane;
    uint32 private immutable i_callbackGasLimit; // {gas}
    bool private immutable i_nativePayment; // true = pay with ETH, false = pay with LINK

    /// @notice Max bets per round, so a round with every bet winning settles within the callback gas limit
    /// @dev Sized by test/gas/CallbackGas.t.sol with cold storage: worst case ~51k gas per winning
    ///      bet + ~149k fixed, 40 bets ~2.19M of the 2.5M callback gas limit (~12% headroom)
    uint256 public constant MAX_BETS_PER_ROUND = 40; // {count}
    uint256 private constant BPS = 10_000; // BPS{1} = 100%
    /// @notice Lower bound for vrfTimeout, so the owner can't refund a round right after seeing its result
    uint256 public constant MIN_VRF_TIMEOUT = 1 hours; // {s}

    RouletteVault public immutable vault;
    IERC20 public immutable usdc;

    // Roulette state
    RouletteTypes.RouletteState public state;
    uint256 public minBet; // D6{USDC}
    uint256 public maxBet; // D6{USDC}
    uint256 public currentRoundId; // {id}
    uint256 public betIdCounter; // {id}
    uint256 public spinDelay; // {s} duration
    uint256 public lastSpinTimestamp; // {s} timestamp
    uint256 public spinRequestedAt; // {s} timestamp
    /// @notice Max net worst-case payout of a round, in bps of vault assets
    uint256 public maxExposureBps; // BPS{1} [0, BPS]
    /// @notice Time after a spin request before the owner can refund the round
    uint256 public vrfTimeout; // {s} duration, >= MIN_VRF_TIMEOUT
    /// @notice USDC owed by the vault after a round it could not fully cover
    uint256 public deficit; // D6{USDC}

    // Player credits (1:1 with USDC held by this contract)
    mapping(address => uint256) public credits; // D6{credit} (= D6{USDC})
    uint256 public totalCredits; // D6{credit} (= D6{USDC})

    // House statistics
    uint256 public totalWagered; // D6{USDC} sum of settled stakes
    uint256 public totalPaidOut; // D6{USDC} gross: stake + winnings
    int256 public houseNetPnl; // signed D6{USDC} = -Σ netToPlayers

    mapping(uint256 requestId => uint256 roundId) private s_requestIdToRoundId;
    mapping(uint256 => RouletteTypes.Round) private s_rounds;
    mapping(uint256 => RouletteTypes.Bet) private s_bets;
    mapping(address => RouletteTypes.PlayerStats) private s_playerStats;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event StateChanged(RouletteTypes.RouletteState indexed newState);
    event CreditsDeposited(address indexed player, uint256 amount); // amount: D6{USDC} -> D6{credit} 1:1
    event CreditsWithdrawn(address indexed player, uint256 amount); // amount: D6{credit} -> D6{USDC} 1:1
    event BetPlaced(
        uint256 indexed roundId,
        uint256 indexed betId,
        address indexed player,
        RouletteTypes.BetType betType,
        uint40 numbersMask, // bit n set = bet covers number n
        uint256 amount // D6{USDC} stake
    );
    event SpinRequested(uint256 indexed roundId, uint256 timestamp); // timestamp: {s}
    event BetWon(uint256 indexed betId, address indexed player, uint256 payout); // payout: D6{USDC} gross
    // winningNumber: {pocket}; totalPayout: D6{USDC} gross
    event SpinCompleted(
        uint256 indexed roundId, uint8 winningNumber, RouletteTypes.Color winningColor, uint256 totalPayout
    );
    // totalBets: D6{USDC} stakes; totalPayout: D6{USDC} gross; netToPlayers: signed D6{USDC}
    event RoundSettled(uint256 indexed roundId, uint256 totalBets, uint256 totalPayout, int256 netToPlayers);
    event DeficitRecorded(uint256 indexed roundId, uint256 deficit); // deficit: D6{USDC}
    event DeficitCovered(uint256 amount, uint256 remaining); // D6{USDC}, D6{USDC}
    event RoundRefunded(uint256 indexed roundId);
    event MinBetUpdated(uint256 oldMinBet, uint256 newMinBet); // D6{USDC}
    event MaxBetUpdated(uint256 oldMaxBet, uint256 newMaxBet); // D6{USDC}
    event SpinDelayUpdated(uint256 oldDelay, uint256 newDelay); // {s}
    event MaxExposureBpsUpdated(uint256 oldBps, uint256 newBps); // BPS{1}
    event VrfTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout); // {s}
    event ExcessSwept(address indexed to, uint256 amount); // D6{USDC}

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
    error Roulette__OnlyVrfCoordinator();
    error Roulette__VrfTimeoutTooShort();
    error Roulette__InvalidBetLimits();
    error Roulette__NothingToSweep();

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
     * @param _minBet D6{USDC} Minimum bet amount
     * @param _maxBet D6{USDC} Maximum bet amount
     * @param _spinDelay {s} Minimum delay between spins in seconds
     * @param _maxExposureBps BPS{1} Max net worst-case payout of a round, in bps of vault assets
     * @param _vrfTimeout {s} Time after a spin request before the owner can refund the round
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
        uint256 _spinDelay,
        uint256 _maxExposureBps,
        uint256 _vrfTimeout
    ) Ownable(msg.sender) {
        if (_maxExposureBps > BPS) revert Roulette__InvalidBps();
        if (_vrfTimeout < MIN_VRF_TIMEOUT) revert Roulette__VrfTimeoutTooShort();
        _checkBetLimits(_minBet, _maxBet);
        i_vrfCoordinator = IVRFCoordinatorV2Plus(_vrfCoordinator);
        i_subscriptionId = _subscriptionId;
        i_gasLane = _gasLane;
        i_callbackGasLimit = _callbackGasLimit;
        i_nativePayment = _nativePayment;

        vault = RouletteVault(_vault);
        usdc = IERC20(RouletteVault(_vault).asset());
        minBet = _minBet;
        maxBet = _maxBet;
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
     * @param amount D6{USDC} Amount of USDC to deposit (credited 1:1 as D6{credit})
     */
    function depositCredits(uint256 amount) external nonReentrant {
        if (amount == 0) revert Roulette__InvalidAmount();

        // D6{credit} += D6{USDC} (1:1)
        credits[msg.sender] += amount;
        totalCredits += amount;
        emit CreditsDeposited(msg.sender, amount);

        usdc.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraw credits back to USDC
     * @dev Allowed in every state. During a deficit, withdrawals are first come, first served:
     *      once this contract's balance runs out, they revert until the deficit is covered.
     * @param amount D6{credit} Amount of credits to withdraw (paid 1:1 as D6{USDC})
     */
    function withdrawCredits(uint256 amount) external nonReentrant {
        if (amount == 0) revert Roulette__InvalidAmount();
        if (credits[msg.sender] < amount) revert Roulette__InsufficientCredits();
        if (state == RouletteTypes.RouletteState.DEFICIT && usdc.balanceOf(address(this)) < amount) {
            revert Roulette__InsufficientRouletteBalance();
        }

        // D6{credit} -= D6{credit}; paid out 1:1 as D6{USDC}
        credits[msg.sender] -= amount;
        totalCredits -= amount;
        emit CreditsWithdrawn(msg.sender, amount);

        usdc.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Place a bet using credits
     * @param betType Type of bet
     * @param numbers Numbers to bet on (depends on bet type)
     * @param amount D6{credit} Amount to bet (stake, D6{USDC})
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
        uint256 playerCredits = credits[msg.sender]; // D6{credit}
        if (playerCredits < amount) revert Roulette__InsufficientCredits();

        uint256 roundId = currentRoundId;
        uint256 betId = ++betIdCounter;
        _addBetToRound(roundId, betId, betType, amount);

        // Debit credits; the USDC stays here as the round's stake
        // D6{credit} = D6{credit} - D6{credit}
        credits[msg.sender] = playerCredits - amount;
        totalCredits -= amount;

        s_bets[betId] = RouletteTypes.Bet({
            player: msg.sender, betType: betType, numbersMask: numbersMask, amount: amount.toUint48()
        });
        _recordPlayerBet(roundId, amount);

        emit BetPlaced(roundId, betId, msg.sender, betType, numbersMask, amount);
    }

    /**
     * @notice Request spin - changes state to CALCULATING and requests random number from Chainlink VRF
     * @dev The winning number is determined in the fulfillRandomWords callback
     */
    function spin() external nonReentrant onlyOwner whenNotPaused {
        if (state != RouletteTypes.RouletteState.OPEN) revert Roulette__AlreadyCalculating();

        uint256 lastSpin = lastSpinTimestamp; // {s}
        if (lastSpin > 0) {
            // {s} = {s} - {s}
            uint256 timeSinceLastSpin = block.timestamp - lastSpin;
            if (timeSinceLastSpin < spinDelay) revert Roulette__SpinDelayNotMet(spinDelay - timeSinceLastSpin);
        }

        uint256 roundId = currentRoundId;
        if (s_rounds[roundId].firstBetId == 0) revert Roulette__NoActiveBets();

        _setState(RouletteTypes.RouletteState.CALCULATING);
        spinRequestedAt = block.timestamp;

        uint256 requestId = i_vrfCoordinator.requestRandomWords(
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

        uint256 owed = deficit; // D6{USDC}
        uint256 amount = usdc.balanceOf(address(vault)); // D6{USDC}
        if (amount == 0) revert Roulette__NothingToCover();
        // D6{USDC} = min(D6{USDC} vault balance, D6{USDC} owed)
        if (amount > owed) amount = owed;

        // D6{USDC} = D6{USDC} - D6{USDC}
        owed -= amount;
        deficit = owed;
        if (owed == 0) _setState(RouletteTypes.RouletteState.OPEN);
        emit DeficitCovered(amount, owed);

        vault.fundPayout(amount);
    }

    /**
     * @notice Refund the current round when Chainlink VRF never answered, or betting was stopped
     * @dev Re-credits every stake and rolls back the bets' stats. A late VRF answer for the
     *      refunded round reverts with InvalidRequestId.
     *      With a VRF request pending only the owner can refund: anyone else could see a late answer
     *      in the mempool and cancel a round they lost. After an emergency stop no answer can come,
     *      so anyone can refund once vrfTimeout has passed and the owner can't keep LPs locked.
     */
    function refundRound() external nonReentrant {
        if (state != RouletteTypes.RouletteState.CALCULATING) revert Roulette__NotCalculating();
        uint256 roundId = currentRoundId;
        RouletteTypes.Round storage round = s_rounds[roundId];
        if (round.requestId != 0) _checkOwner();

        // {s} = {s} - {s}
        uint256 elapsed = block.timestamp - spinRequestedAt;
        if (elapsed < vrfTimeout) revert Roulette__VrfTimeoutNotReached(vrfTimeout - elapsed);

        uint256 lastBetId = round.lastBetId;
        for (uint256 betId = round.firstBetId; betId != 0 && betId <= lastBetId; ++betId) {
            RouletteTypes.Bet memory bet = s_bets[betId];
            credits[bet.player] += bet.amount; // D6{credit} += D6{USDC} stake (1:1)

            RouletteTypes.PlayerStats storage stats = s_playerStats[bet.player];
            stats.totalBets -= 1; // {count}
            stats.totalWagered -= bet.amount; // D6{USDC}
            // lastRoundWagered stays: the round is marked completed below, so getPlayerStats ignores it
        }
        // D6{credit} += D6{USDC} (sum of stakes, refunded 1:1)
        totalCredits += round.totalBets;

        delete s_requestIdToRoundId[round.requestId];
        round.completed = true;
        round.refunded = true;

        currentRoundId = roundId + 1;
        _setState(RouletteTypes.RouletteState.OPEN);
        emit RoundRefunded(roundId);
    }

    /// @notice Update minimum bet, keeping 0 < minBet <= maxBet
    function setMinBet(uint256 _minBet) external onlyOwner {
        _checkBetLimits(_minBet, maxBet);
        emit MinBetUpdated(minBet, _minBet);
        minBet = _minBet;
    }

    /// @notice Update maximum bet, keeping minBet <= maxBet <= uint48 max (a bet's stored amount)
    function setMaxBet(uint256 _maxBet) external onlyOwner {
        _checkBetLimits(minBet, _maxBet);
        emit MaxBetUpdated(maxBet, _maxBet);
        maxBet = _maxBet;
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
        if (_vrfTimeout < MIN_VRF_TIMEOUT) revert Roulette__VrfTimeoutTooShort();
        emit VrfTimeoutUpdated(vrfTimeout, _vrfTimeout);
        vrfTimeout = _vrfTimeout;
    }

    /**
     * @notice Send USDC held beyond what Roulette owes to `to`
     * @dev Recovers plain transfers to this contract, which back no credits
     * @param to Recipient of the excess
     */
    function sweepExcess(address to) external nonReentrant onlyOwner {
        uint256 excess = excessUsdc(); // D6{USDC}
        if (excess == 0) revert Roulette__NothingToSweep();
        emit ExcessSwept(to, excess);
        usdc.safeTransfer(to, excess);
    }

    /// @notice Pause the contract
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Emergency function to force state to CALCULATING (stops betting)
     * @dev Starts the refund clock, so refundRound can't use the previous spin's timestamp.
     *      Only from OPEN: calling it again while CALCULATING would push a pending refund back forever.
     */
    function emergencyStopBetting() external onlyOwner {
        if (state == RouletteTypes.RouletteState.DEFICIT) revert Roulette__DeficitOpen();
        if (state == RouletteTypes.RouletteState.CALCULATING) revert Roulette__AlreadyCalculating();
        spinRequestedAt = block.timestamp;
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
        // D6{USDC} net worst case = D6{USDC} gross maxExposure - D6{USDC} stakes
        reserved = round.maxExposure - round.totalBets;
    }

    /**
     * @notice USDC held beyond the credits and the stakes of the round in progress
     * @dev 0 while a deficit is open: the contract is short, not in excess
     * @return D6{USDC} excess balance
     */
    function excessUsdc() public view returns (uint256) {
        if (state == RouletteTypes.RouletteState.DEFICIT) return 0;
        RouletteTypes.Round storage round = s_rounds[currentRoundId];
        // D6{USDC} = D6{credit} (1:1) + D6{USDC} open stakes
        uint256 owed = totalCredits + (round.completed ? 0 : round.totalBets);
        uint256 balance = usdc.balanceOf(address(this)); // D6{USDC}
        // D6{USDC} = D6{USDC} - D6{USDC}
        return balance > owed ? balance - owed : 0;
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
     * @return payout D6{USDC} gross: Stake + winnings if the bet won
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
        // D6{USDC} = D6{USDC} * D0{1}(mult + 1)
        if (won) payout = uint256(bet.amount) * (RouletteTypes.getPayoutMultiplier(bet.betType) + 1);
    }

    /// @notice Get player statistics. totalLost excludes stakes of the round in progress.
    function getPlayerStats(address player) external view returns (RouletteTypes.PlayerStatsView memory view_) {
        RouletteTypes.PlayerStats storage stats = s_playerStats[player];
        uint256 pending = s_rounds[stats.lastRoundId].completed ? 0 : stats.lastRoundWagered; // D6{USDC}

        view_.totalBets = stats.totalBets; // {count} (PlayerStats.totalBets, not Round.totalBets)
        view_.totalWagered = stats.totalWagered; // D6{USDC}
        view_.totalWon = stats.totalWon; // D6{USDC} net
        // D6{USDC} = D6{USDC} - D6{USDC} - D6{USDC}
        view_.totalLost = stats.totalWagered - stats.totalWonStakes - pending;
        view_.lastPlayedTimestamp = stats.lastPlayedTimestamp; // {s}
    }

    /// @notice Get house statistics
    /// @return wagered D6{USDC} settled stakes
    /// @return paidOut D6{USDC} gross payouts
    /// @return netPnl signed D6{USDC} house net PnL
    function getHouseStats() external view returns (uint256 wagered, uint256 paidOut, int256 netPnl) {
        return (totalWagered, totalPaidOut, houseNetPnl);
    }

    /// @notice Get round details
    function getRound(uint256 roundId) external view returns (RouletteTypes.Round memory) {
        return s_rounds[roundId];
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
        return (address(i_vrfCoordinator), i_subscriptionId, i_gasLane, i_callbackGasLimit, i_nativePayment);
    }

    /// @notice Get round ID from VRF request ID
    function getRequestIdToRoundId(uint256 requestId) external view returns (uint256) {
        return s_requestIdToRoundId[requestId];
    }

    /*//////////////////////////////////////////////////////////////
                     INTERNAL READ-ONLY FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @dev 0 < minBet <= maxBet <= uint48 max, so every accepted bet amount fits in Bet.amount
    function _checkBetLimits(uint256 _minBet, uint256 _maxBet) internal pure {
        if (_minBet == 0 || _minBet > _maxBet || _maxBet > type(uint48).max) revert Roulette__InvalidBetLimits();
    }

    /*//////////////////////////////////////////////////////////////
                   INTERNAL STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @dev Adds a bet to the round: bet id range, bet count cap and exposure limit
     *      (the round's net worst case must stay within maxExposureBps of vault assets).
     */
    function _addBetToRound(uint256 roundId, uint256 betId, RouletteTypes.BetType betType, uint256 amount) internal {
        RouletteTypes.Round storage round = s_rounds[roundId];

        if (round.firstBetId == 0) {
            round.firstBetId = betId.toUint64();
            // forge-lint: disable-next-line(unsafe-typecast) timestamps fit in uint64
            round.timestamp = uint64(block.timestamp); // {s}
            round.winningNumber = type(uint8).max;
        } else if (betId - round.firstBetId >= MAX_BETS_PER_ROUND) {
            // {count} = {id} - {id}, vs {count}
            revert Roulette__RoundFull();
        }
        // forge-lint: disable-next-line(unsafe-typecast) bet ids can't reach 2^64
        round.lastBetId = uint64(betId);

        // D6{USDC} = D6{USDC} + D6{USDC}
        uint256 roundTotalBets = round.totalBets + amount;
        // D6{USDC} gross = D6{USDC} + D6{USDC} * D0{1}(mult + 1)
        uint256 roundMaxExposure = round.maxExposure + amount * (RouletteTypes.getPayoutMultiplier(betType) + 1);
        // D6{USDC} net * BPS > D6{USDC} * BPS{1}  <=>  net / totalAssets > maxExposureBps / BPS
        if ((roundMaxExposure - roundTotalBets) * BPS > vault.totalAssets() * maxExposureBps) {
            revert Roulette__ExposureLimitExceeded();
        }
        round.totalBets = roundTotalBets.toUint128(); // D6{USDC} stakes (Round.totalBets, not a count)
        round.maxExposure = roundMaxExposure; // D6{USDC} gross
    }

    /// @dev Updates the bettor's stats at bet time (two slots; settlement only touches winners)
    function _recordPlayerBet(uint256 roundId, uint256 amount) internal {
        RouletteTypes.PlayerStats storage stats = s_playerStats[msg.sender];
        if (stats.lastRoundId != roundId) {
            // forge-lint: disable-next-line(unsafe-typecast) round ids can't reach 2^64
            stats.lastRoundId = uint64(roundId);
            stats.lastRoundWagered = 0; // D6{USDC}
        }
        // forge-lint: disable-next-line(unsafe-typecast) amount fits in uint48 (checked when storing the bet)
        stats.lastRoundWagered += uint120(amount); // D6{USDC}
        stats.totalBets += 1; // {count}
        // forge-lint: disable-next-line(unsafe-typecast) timestamps fit in uint40 until ~year 36800
        stats.lastPlayedTimestamp = uint40(block.timestamp); // {s}
        stats.totalWagered += amount; // D6{USDC}
    }

    /*//////////////////////////////////////////////////////////////
                              VRF CALLBACK
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Callback called by Chainlink VRF with the random number
     * @dev Must not revert for funding reasons: Chainlink does not retry. Settles every bet of the
     *      round in one loop, then moves the round's net amount between Roulette and the vault.
     */
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(i_vrfCoordinator)) revert Roulette__OnlyVrfCoordinator();
        uint256 roundId = s_requestIdToRoundId[requestId];
        if (roundId == 0) revert Roulette__InvalidRequestId();
        delete s_requestIdToRoundId[requestId];

        RouletteTypes.Round storage round = s_rounds[roundId];
        uint8 winningNumber = uint8(randomWords[0] % RouletteTypes.WHEEL_SIZE); // {pocket} 0..36
        RouletteTypes.Color winningColor = RouletteTypes.getNumberColor(winningNumber);

        uint256 totalPayout; // D6{USDC} gross
        uint256 lastBetId = round.lastBetId;
        for (uint256 betId = round.firstBetId; betId <= lastBetId; ++betId) {
            RouletteTypes.Bet memory bet = s_bets[betId];
            if (!RouletteTypes.checkWin(bet.numbersMask, winningNumber)) continue;

            // D6{USDC} net = D6{USDC} * D0{1}
            uint256 winnings = uint256(bet.amount) * RouletteTypes.getPayoutMultiplier(bet.betType);
            // D6{USDC} gross = D6{USDC} stake + D6{USDC} net
            uint256 payout = bet.amount + winnings;
            totalPayout += payout; // D6{USDC} gross
            credits[bet.player] += payout; // D6{credit} += D6{USDC} gross (1:1)

            RouletteTypes.PlayerStats storage stats = s_playerStats[bet.player];
            // forge-lint: disable-next-line(unsafe-typecast) winnings <= uint48 amount * 35
            stats.totalWon += uint128(winnings); // D6{USDC} net
            stats.totalWonStakes += bet.amount; // D6{USDC} stake

            emit BetWon(betId, bet.player, payout);
        }

        uint256 roundTotalBets = round.totalBets; // D6{USDC} stakes
        // signed D6{USDC} = D6{USDC} gross payout - D6{USDC} stakes
        // forge-lint: disable-next-line(unsafe-typecast) both are bounded by uint128 round totals
        int256 netToPlayers = int256(totalPayout) - int256(roundTotalBets);

        // D6{credit} += D6{USDC} gross (1:1)
        totalCredits += totalPayout;
        totalWagered += roundTotalBets; // D6{USDC} stakes
        totalPaidOut += totalPayout; // D6{USDC} gross
        houseNetPnl -= netToPlayers; // signed D6{USDC}

        round.winningNumber = winningNumber;
        round.winningColor = winningColor;
        round.completed = true;
        // forge-lint: disable-next-line(unsafe-typecast) payout <= round maxExposure, bounded by MAX_BETS_PER_ROUND uint48 bets
        round.totalPayout = uint128(totalPayout); // D6{USDC} gross

        lastSpinTimestamp = block.timestamp; // {s}
        currentRoundId = roundId + 1;

        emit SpinCompleted(roundId, winningNumber, winningColor, totalPayout);
        emit RoundSettled(roundId, roundTotalBets, totalPayout, netToPlayers);

        _settleWithVault(roundId, netToPlayers);
    }

    /**
     * @dev Moves the round's net amount between Roulette and the vault. If the vault can't cover
     *      the players' net winnings, pulls what it has and records the rest as a deficit.
     * @param netToPlayers signed D6{USDC} (gross payout - stakes); < 0 means house won
     */
    function _settleWithVault(uint256 roundId, int256 netToPlayers) internal {
        if (netToPlayers < 0) {
            _setState(RouletteTypes.RouletteState.OPEN);
            // forge-lint: disable-next-line(unsafe-typecast) netToPlayers < 0
            usdc.safeTransfer(address(vault), uint256(-netToPlayers)); // D6{USDC} house net winnings
            return;
        }
        if (netToPlayers == 0) {
            _setState(RouletteTypes.RouletteState.OPEN);
            return;
        }

        // forge-lint: disable-next-line(unsafe-typecast) netToPlayers > 0
        uint256 owed = uint256(netToPlayers); // D6{USDC}
        uint256 available = usdc.balanceOf(address(vault)); // D6{USDC}
        if (available >= owed) {
            _setState(RouletteTypes.RouletteState.OPEN);
            vault.fundPayout(owed); // D6{USDC} net player winnings
            return;
        }

        // D6{USDC} = D6{USDC} - D6{USDC}
        deficit = owed - available;
        _setState(RouletteTypes.RouletteState.DEFICIT);
        emit DeficitRecorded(roundId, owed - available);
        if (available > 0) vault.fundPayout(available); // D6{USDC} partial cover
    }

    function _setState(RouletteTypes.RouletteState newState) internal {
        state = newState;
        emit StateChanged(newState);
    }
}
