// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title IRouletteCredits
 * @notice Interface for Roulette credit management functions
 */
interface IRouletteCredits {
    function addCredits(address player, uint256 amount) external;
    function removeCredits(address player, uint256 amount) external;
}

/**
 * @title RouletteVault
 * @notice ERC4626 vault that acts as the house bank for the roulette
 * @dev Liquidity providers deposit USDC and receive shares (yield bearing)
 *      Players deposit USDC for credits (managed by Roulette contract)
 *      The vault holds all USDC and pays out winnings
 * 
 * @dev Capacity Management:
 *      - maxCapacity only applies to LP deposits (shares)
 *      - Player credits do NOT count towards capacity
 *      - This prevents APR dilution from excessive LP deposits
 *      - lpCapital tracks only USDC that generated shares
 */
contract RouletteVault is ERC4626, Ownable, ReentrancyGuard {
    // Errors
    error UnauthorizedCaller();
    error InsufficientVaultBalance();
    error MaxCapacityReached();
    error InvalidAmount();

    // State variables
    address public roulette;
    uint256 public maxCapacity;
    
    // Track LP capital separately from player credits
    uint256 public lpCapital; // Only USDC that generated shares
    
    // Statistics
    uint256 public totalBetsPlaced;
    uint256 public totalPayouts;
    uint256 public totalProfit;
    
    // Events
    event RouletteSet(address indexed roulette);
    event MaxCapacityUpdated(uint256 oldCapacity, uint256 newCapacity);
    event CreditsDeposited(address indexed player, uint256 amount);
    event CreditsWithdrawn(address indexed player, uint256 amount);
    event BetPlaced(uint256 amount);
    event PayoutProcessed(address indexed player, uint256 amount);
    event ProfitRecorded(uint256 profit);
    event LossRecorded(uint256 loss);

    // Modifiers
    modifier onlyRoulette() {
        if (msg.sender != roulette) revert UnauthorizedCaller();
        _;
    }

    /**
     * @notice Constructor
     * @param _asset USDC token address
     * @param _name Vault token name
     * @param _symbol Vault token symbol
     * @param _maxCapacity Maximum vault capacity
     */
    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        uint256 _maxCapacity
    ) ERC4626(IERC20(_asset)) ERC20(_name, _symbol) Ownable(msg.sender) {
        maxCapacity = _maxCapacity;
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the roulette contract address
     * @param _roulette Roulette contract address
     */
    function setRoulette(address _roulette) external onlyOwner {
        require(_roulette != address(0), "Invalid address");
        roulette = _roulette;
        emit RouletteSet(_roulette);
    }

    /**
     * @notice Update maximum vault capacity
     * @param _maxCapacity New maximum capacity
     */
    function setMaxCapacity(uint256 _maxCapacity) external onlyOwner {
        uint256 oldCapacity = maxCapacity;
        maxCapacity = _maxCapacity;
        emit MaxCapacityUpdated(oldCapacity, _maxCapacity);
    }

    // ============ Liquidity Provider Functions ============

    /**
     * @notice Deposit assets and receive shares (for liquidity providers)
     * @dev Overrides ERC4626 to add capacity check based on LP capital only
     */
    function deposit(uint256 assets, address receiver) 
        public 
        override 
        nonReentrant 
        returns (uint256) 
    {
        // Check capacity only for LP deposits (shares)
        uint256 newLPCapital = lpCapital + assets;
        if (newLPCapital > maxCapacity) revert MaxCapacityReached();
        
        // Update LP capital tracking
        lpCapital = newLPCapital;
        
        return super.deposit(assets, receiver);
    }

    /**
     * @notice Mint shares and receive assets (for liquidity providers)
     * @dev Overrides ERC4626 to add capacity check based on LP capital only
     */
    function mint(uint256 shares, address receiver) 
        public 
        override 
        nonReentrant 
        returns (uint256) 
    {
        uint256 assets = previewMint(shares);
        
        // Check capacity only for LP deposits (shares)
        uint256 newLPCapital = lpCapital + assets;
        if (newLPCapital > maxCapacity) revert MaxCapacityReached();
        
        // Update LP capital tracking
        lpCapital = newLPCapital;
        
        return super.mint(shares, receiver);
    }

    /**
     * @notice Withdraw assets by burning shares (for liquidity providers)
     * @dev Overrides ERC4626 to update LP capital tracking
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256)
    {
        // Decrease LP capital tracking
        lpCapital -= assets;
        
        return super.withdraw(assets, receiver, owner);
    }

    /**
     * @notice Redeem shares for assets (for liquidity providers)
     * @dev Overrides ERC4626 to update LP capital tracking
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256)
    {
        uint256 assets = previewRedeem(shares);
        
        // Decrease LP capital tracking
        lpCapital -= assets;
        
        return super.redeem(shares, receiver, owner);
    }

    // ============ Player Credits Functions ============

    /**
     * @notice Deposit USDC to receive credits for betting (1:1 ratio)
     * @dev Credits are managed by Roulette contract, USDC stays in vault
     * @param amount Amount of USDC to deposit
     */
    function depositCredits(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (roulette == address(0)) revert UnauthorizedCaller();
        
        // Transfer USDC from player to vault
        IERC20(asset()).transferFrom(msg.sender, address(this), amount);
        
        // Call Roulette to credit player (1:1)
        IRouletteCredits(roulette).addCredits(msg.sender, amount);
        
        emit CreditsDeposited(msg.sender, amount);
    }

    /**
     * @notice Withdraw credits back to USDC
     * @param amount Amount of credits to withdraw
     */
    function withdrawCredits(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (roulette == address(0)) revert UnauthorizedCaller();
        
        // Call Roulette to deduct credits
        IRouletteCredits(roulette).removeCredits(msg.sender, amount);
        
        // Transfer USDC back to player
        IERC20(asset()).transfer(msg.sender, amount);
        
        emit CreditsWithdrawn(msg.sender, amount);
    }

    // ============ Roulette Integration Functions ============

    /**
     * @notice Record bet amount (called by Roulette when bet is placed)
     * @param amount Amount of bet
     */
    function recordBet(uint256 amount) external onlyRoulette {
        totalBetsPlaced += amount;
        emit BetPlaced(amount);
    }

    /**
     * @notice Process payout to winner (called by Roulette)
     * @dev USDC stays in vault, Roulette will credit player with credits
     * @param player Player address
     * @param amount Payout amount
     */
    function payout(address player, uint256 amount) external onlyRoulette nonReentrant {
        // Check vault has enough liquidity
        uint256 availableBalance = IERC20(asset()).balanceOf(address(this));
        if (availableBalance < amount) revert InsufficientVaultBalance();
        
        // USDC stays in vault, just credit the player via Roulette
        // Roulette will call addCredits internally after this
        
        // Track statistics
        totalPayouts += amount;
        
        emit PayoutProcessed(player, amount);
    }

    /**
     * @notice Record profit from losing bets (called by Roulette)
     * @param amount Profit amount
     */
    function recordProfit(uint256 amount) external onlyRoulette {
        totalProfit += amount;
        emit ProfitRecorded(amount);
    }

    /**
     * @notice Record loss from winning bets (called by Roulette)
     * @param amount Loss amount
     */
    function recordLoss(uint256 amount) external onlyRoulette {
        // totalProfit can go negative (represented as totalProfit - amount)
        if (amount > totalProfit) {
            totalProfit = 0;
        } else {
            totalProfit -= amount;
        }
        emit LossRecorded(amount);
    }

    // ============ View Functions ============

    /**
     * @notice Get available liquidity in the vault
     * @return Available USDC balance
     */
    function getAvailableLiquidity() external view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /**
     * @notice Get vault statistics
     * @return _totalAssets Total assets in vault (LP capital + player credits)
     * @return _lpCapital LP capital only (generates shares)
     * @return _totalBets Total bets placed
     * @return _totalPayouts Total payouts made
     * @return _totalProfit Total profit accumulated
     */
    function getVaultStats() 
        external 
        view 
        returns (
            uint256 _totalAssets,
            uint256 _lpCapital,
            uint256 _totalBets,
            uint256 _totalPayouts,
            uint256 _totalProfit
        ) 
    {
        return (
            totalAssets(),
            lpCapital,
            totalBetsPlaced,
            totalPayouts,
            totalProfit
        );
    }

    /**
     * @notice Get LP capacity information
     * @return _lpCapital Current LP capital
     * @return _maxCapacity Maximum LP capacity
     * @return _availableCapacity Remaining capacity for LP deposits
     */
    function getLPCapacityInfo()
        external
        view
        returns (
            uint256 _lpCapital,
            uint256 _maxCapacity,
            uint256 _availableCapacity
        )
    {
        uint256 available = maxCapacity > lpCapital ? maxCapacity - lpCapital : 0;
        return (lpCapital, maxCapacity, available);
    }

    /**
     * @notice Get max bet size based on available liquidity
     * @param multiplier Bet payout multiplier (e.g., 35 for straight up)
     * @return Maximum bet amount
     */
    function getMaxBet(uint256 multiplier) external view returns (uint256) {
        uint256 liquidity = IERC20(asset()).balanceOf(address(this));
        
        // Max bet = Liquidity / (Multiplier + 1)
        // This ensures vault can always pay the max win
        if (multiplier == 0) return 0;
        return liquidity / (multiplier + 1);
    }
}
