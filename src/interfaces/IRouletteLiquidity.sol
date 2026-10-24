// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/**
 * @title IRouletteLiquidity
 * @notice Views the vault reads from Roulette to limit LP deposits and withdrawals
 */
interface IRouletteLiquidity {
    /// @notice True while a spin is pending or a deficit is open: all LP actions are blocked
    function lpLocked() external view returns (bool);

    /// @notice Net worst-case payout of the open round, which LP withdrawals must leave in the vault
    function reservedLiquidity() external view returns (uint256);
}
