# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DWheel is a decentralized on-chain casino roulette protocol combining gaming with DeFi. Players deposit USDC to obtain credits for betting, while liquidity providers (LPs) earn yields through an ERC4626 vault system. The protocol uses Chainlink VRF for verifiable randomness.

**Current Status**: Phase 2 Complete (vault + credits system). Phase 3 (frontend) is in progress.

## Build & Test Commands

```bash
# Build contracts
forge build

# Run all tests
forge test

# Run tests with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/Roulette.t.sol

# Run specific test by name
forge test --match-test testVault_LPYieldAccumulation

# Coverage report
forge coverage

# Deploy locally
forge script script/DeployRoulette.s.sol --rpc-url $RPC_URL --broadcast
```

**Frontend** (in `/frontend`):
```bash
npm install
npm run dev     # Start dev server on port 3000
npm run build   # Production build
```

## Architecture

```
Players                     Roulette.sol              RouletteVault.sol (ERC4626)
   │                             │                            │
   │  depositCredits(USDC)       │                            │
   │────────────────────────────────────────────────────────>│
   │  placeBet(credits)          │                            │
   │────────────────────────────>│  recordBet()               │
   │                             │───────────────────────────>│
   │                             │  VRF Request ──> Chainlink │
   │  payout (if win)            │  payout()                  │
   │<────────────────────────────│<───────────────────────────│

LPs deposit USDC → receive vault shares → earn yield from house edge profits
```

### Key Contracts

- **Roulette.sol** - Game logic, VRF integration, bet placement/settlement, credits management
- **RouletteVault.sol** - ERC4626 vault for USDC, handles LP deposits, player credits, payouts
- **RouletteTypes.sol** - Library with bet type enums, structs, validation functions

### Design Patterns

1. **Dual Accounting**: `lpCapital` (capped) vs `playerCredits` (unlimited) prevents LP capacity limits from blocking players
2. **Credits System**: Players bet with internal credits (1:1 with USDC), no token approvals per bet
3. **Dynamic Max Bet**: `maxBet = availableLiquidity × maxBetMultiplier` protects vault from single large losses
4. **Access Control**: Only Roulette can call `vault.payout()`, `vault.recordBet()`, etc.

## Testing

82 comprehensive tests with high coverage:
- **RouletteVault.sol**: 98.57% line coverage
- **Roulette.sol**: 93.66% line coverage

Tests use `MockUSDC` (6 decimals) and `VRFCoordinatorV2Mock` for deterministic testing.

## Key Parameters

- **Roulette**: European (0-36), ~2.7% house edge, 13 bet types (STRAIGHT_UP 35:1 through RED/BLACK 1:1)
- **Vault**: USDC asset, configurable LP capacity (default 10M), maxBetMultiplier (default 1%)
- **States**: OPEN (accepting bets) ↔ CALCULATING (VRF pending)

## Network Configuration

Handled by `script/HelperConfig.s.sol`:
- **Sepolia**: Uses real USDC (`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`)
- **Anvil**: Deploys MockUSDC and VRFCoordinatorV2Mock

## Frontend Stack

React + TypeScript + Vite + Wagmi/Viem. Key files:
- `frontend/src/config.ts` - Contract addresses, bet types, test accounts
- `frontend/src/abis.ts` - Contract ABIs for wagmi hooks
