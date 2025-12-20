// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Imports
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockToken
 * @notice ERC20 token for testing purposes in Phase 1
 * @dev Token can be minted when players win and burned when they place bets
 * This is only for testing - Phase 2 will use real USDC/USDT
 */
contract MockToken is ERC20, Ownable {
    // Errors
    error Unauthorized();

    // State variables
    uint8 private constant DECIMALS = 18;
    mapping(address => bool) public authorized;

    // Events
    event AuthorizationChanged(address indexed account, bool authorized);

    // Constructor
    /**
     * @notice Constructor to initialize the MockToken
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param initialSupply Initial supply to mint to deployer
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply);
        }
        authorized[msg.sender] = true;
    }

    // External functions
    /**
     * @notice Authorize or deauthorize an address to mint/burn
     * @param account Address to change authorization for
     * @param status New authorization status
     */
    function setAuthorized(address account, bool status) external onlyOwner {
        authorized[account] = status;
        emit AuthorizationChanged(account, status);
    }

    /**
     * @notice Mint tokens to an address
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external {
        if (!authorized[msg.sender]) revert Unauthorized();
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens from an address
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external {
        if (!authorized[msg.sender]) revert Unauthorized();
        _burn(from, amount);
    }

    /**
     * @notice Burn tokens from caller
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /**
     * @notice Faucet function for testing - gives free tokens to caller
     * @param amount Amount to receive from faucet
     */
    function faucet(uint256 amount) external {
        _mint(msg.sender, amount);
    }

    // Public pure functions
    /**
     * @notice Get the number of decimals
     * @return Number of decimals
     */
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
