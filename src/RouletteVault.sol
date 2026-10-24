// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IRouletteLiquidity} from "src/interfaces/IRouletteLiquidity.sol";

/**
 * @title RouletteVault
 * @notice ERC4626 vault that acts as the house bank for the roulette
 * @dev Only liquidity providers use the vault: its whole USDC balance is LP money, so the default
 *      `totalAssets() = balanceOf(this)` is the share price base. Player funds live in Roulette.
 *      Roulette sends the house's net winnings here with a plain transfer, and pulls the players'
 *      net winnings with `fundPayout`.
 *
 *      LP deposits/withdrawals are blocked while Roulette reports `lpLocked()` (spin pending or
 *      deficit open), and withdrawals can't take the vault below Roulette's `reservedLiquidity()`.
 * @custom:security-contact TODO
 */
contract RouletteVault is ERC4626, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /// @dev Virtual shares offset, makes the first-depositor donation attack 10^6 times more expensive
    uint8 private constant DECIMALS_OFFSET = 6;

    IRouletteLiquidity public roulette;
    uint256 public maxCapacity;
    /// @notice Emergency switch: when true, Roulette's lpLocked() is ignored
    bool public lpLockOverride;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event RouletteSet(address indexed roulette);
    event MaxCapacityUpdated(uint256 oldCapacity, uint256 newCapacity);
    event LpLockOverrideUpdated(bool lpLockOverride);
    event PayoutFunded(uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error RouletteVault__UnauthorizedCaller();
    error RouletteVault__InvalidAddress();
    error RouletteVault__RouletteAlreadySet();
    error RouletteVault__InvalidAmount();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier onlyRoulette() {
        _checkRoulette();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @param _asset USDC token address
     * @param _name Vault token name
     * @param _symbol Vault token symbol
     * @param _maxCapacity Maximum LP assets the vault accepts
     */
    constructor(address _asset, string memory _name, string memory _symbol, uint256 _maxCapacity)
        ERC4626(IERC20(_asset))
        ERC20(_name, _symbol)
        Ownable(msg.sender)
    {
        maxCapacity = _maxCapacity;
    }

    /*//////////////////////////////////////////////////////////////
                   USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Set the roulette contract address (once)
     * @param _roulette Roulette contract address
     */
    function setRoulette(address _roulette) external onlyOwner {
        if (_roulette == address(0)) revert RouletteVault__InvalidAddress();
        if (address(roulette) != address(0)) revert RouletteVault__RouletteAlreadySet();
        roulette = IRouletteLiquidity(_roulette);
        emit RouletteSet(_roulette);
    }

    /**
     * @notice Update maximum vault capacity
     * @param _maxCapacity New maximum capacity
     */
    function setMaxCapacity(uint256 _maxCapacity) external onlyOwner {
        emit MaxCapacityUpdated(maxCapacity, _maxCapacity);
        maxCapacity = _maxCapacity;
    }

    /**
     * @notice Emergency switch to ignore Roulette's LP lock
     * @dev Pairs with Roulette's emergency functions if a round gets stuck
     */
    function setLpLockOverride(bool _lpLockOverride) external onlyOwner {
        lpLockOverride = _lpLockOverride;
        emit LpLockOverrideUpdated(_lpLockOverride);
    }

    /**
     * @notice Send USDC to Roulette to cover a round where players won more than they staked
     * @param amount Amount of USDC to send
     */
    function fundPayout(uint256 amount) external nonReentrant onlyRoulette {
        if (amount == 0) revert RouletteVault__InvalidAmount();
        IERC20(asset()).safeTransfer(msg.sender, amount);
        emit PayoutFunded(amount);
    }

    /*//////////////////////////////////////////////////////////////
                     USER-FACING READ-ONLY FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Max assets that can be deposited: remaining capacity, or 0 while locked
    function maxDeposit(address) public view override returns (uint256) {
        if (_isLpLocked()) return 0;
        uint256 capacity = maxCapacity;
        if (capacity == type(uint256).max) return type(uint256).max;
        uint256 assets = totalAssets();
        return capacity > assets ? capacity - assets : 0;
    }

    /// @notice Max shares that can be minted: remaining capacity in shares, or 0 while locked
    function maxMint(address receiver) public view override returns (uint256) {
        uint256 assets = maxDeposit(receiver);
        if (assets == type(uint256).max) return type(uint256).max;
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @notice Max assets an owner can withdraw: keeps the reserved liquidity, or 0 while locked
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (_isLpLocked()) return 0;
        return Math.min(super.maxWithdraw(owner), _freeAssets());
    }

    /// @notice Max shares an owner can redeem: keeps the reserved liquidity, or 0 while locked
    function maxRedeem(address owner) public view override returns (uint256) {
        if (_isLpLocked()) return 0;
        return Math.min(super.maxRedeem(owner), _convertToShares(_freeAssets(), Math.Rounding.Floor));
    }

    /// @notice Whether LP deposits and withdrawals are currently blocked
    function isLpLocked() external view returns (bool) {
        return _isLpLocked();
    }

    /*//////////////////////////////////////////////////////////////
                     INTERNAL READ-ONLY FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function _checkRoulette() internal view {
        if (msg.sender != address(roulette)) revert RouletteVault__UnauthorizedCaller();
    }

    function _isLpLocked() internal view returns (bool) {
        if (lpLockOverride || address(roulette) == address(0)) return false;
        return roulette.lpLocked();
    }

    /// @dev Assets not reserved for the open round's worst-case payout
    function _freeAssets() internal view returns (uint256) {
        uint256 assets = totalAssets();
        if (address(roulette) == address(0)) return assets;
        uint256 reserved = roulette.reservedLiquidity();
        return assets > reserved ? assets - reserved : 0;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }
}
