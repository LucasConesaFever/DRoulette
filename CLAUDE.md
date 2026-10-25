# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DWheel is a decentralized on-chain casino roulette protocol combining gaming with DeFi. Players deposit USDC to obtain credits for betting, while liquidity providers (LPs) earn yields through an ERC4626 vault system. The protocol uses Chainlink VRF for verifiable randomness.

**Current Status**: Player funds moved from the vault into Roulette (see `spec.md`). Frontend in progress.

## Build & Test Commands

```bash
# First checkout: fetch forge-std, openzeppelin-contracts and chainlink-brownie-contracts
git submodule update --init

# Build contracts
forge build

# Run all tests
forge test

# Run tests with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/unit/Roulette.t.sol

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
Players ──depositCredits / withdrawCredits (USDC)──▶ Roulette.sol (holds player USDC, credits, bets)
                                                      │  ▲
                        house net win: transfer ──────┘  │ players net win: vault.fundPayout()
                                                      ▼  │
LPs ──ERC4626 deposit / redeem (USDC)──────────────▶ RouletteVault.sol (holds LP USDC only)
```

Calls go Roulette → Vault. The vault only reads two Roulette views (`lpLocked()`, `reservedLiquidity()`).
Full design: `spec.md`.

### Key Contracts

- **Roulette.sol** - Game logic, VRF integration, credits custody, bet placement, single-loop settlement
- **RouletteVault.sol** - Plain ERC4626 over USDC for LPs; `totalAssets() = balanceOf(vault)`
- **RouletteTypes.sol** - Bet types, packed structs, 37-bit number masks, validation
- **IRouletteLiquidity.sol** - Views the vault reads from Roulette

### Design Patterns

1. **Split custody**: player USDC in Roulette, LP USDC in the vault. One net transfer per round at settlement.
2. **Credits System**: Players bet with internal credits (1:1 with USDC), no token approvals per bet
3. **Exposure limit**: a round's net worst case (`sum(amount × (multiplier + 1)) − stakes`) ≤ `maxExposureBps` of vault assets
4. **LP protection**: LP actions blocked while a spin is pending or a deficit is open; withdrawals keep `reservedLiquidity()` in the vault
5. **Bounded callback**: one-slot bets with a number mask, contiguous bet ids per round, `MAX_BETS_PER_ROUND = 40` sized by a cold-storage gas benchmark
6. **Backstops**: deficit state if the vault can't cover a round (`coverDeficit()`), owner `refundRound()` after `vrfTimeout` if VRF never answers
7. **Fixed VRF coordinator**: immutable, checked in our own `rawFulfillRandomWords`; no `VRFConsumerBaseV2Plus` (its owner-callable `setCoordinator` let the owner veto results), ownership from `Ownable2Step`

## Testing

- `test/unit/` - Roulette and RouletteVault unit + fuzz tests
- `test/RouletteTypes.t.sol` - library tests, mask fuzz tests against a reference implementation
- `test/invariant/` - stateful invariants (exact Roulette solvency, no deficit, vault balance = LP flows + house PnL, reserve coverage, sweepable excess); the handler also drives owner actions (bet limits, exposure, pause, emergency stop/refund, capacity, sweep)
- `test/gas/CallbackGas.t.sol` - callback gas benchmark; also run it with `forge test --isolate --match-path test/gas/CallbackGas.t.sol`
- `test/fuzz/CryticTester.sol` - Echidna / Medusa entry point: same Handler, properties as `property_*` bools (keep in sync with `test/invariant/`)

Echidna and Medusa (need `crytic-compile`; corpora go to `crytic/`, gitignored):

```bash
medusa fuzz --timeout 300
echidna . --contract CryticTester --config echidna.yaml --timeout 300 --workers 8
```

Coverage needs `forge coverage --ir-minimum` (stack too deep without the optimizer).

Tests use `MockUSDC` (6 decimals) and `VRFCoordinatorV2_5Mock` (`fulfillRandomWordsWithOverride` to pick the winning number).

## Key Parameters

- **Roulette**: European (0-36), 13 bet types (STRAIGHT_UP 35:1 through RED/BLACK 1:1), `maxExposureBps` 1000 (10%), `vrfTimeout` 1h, callback gas limit 2.5M
- **Vault**: USDC asset, configurable LP capacity (default 10M), shares have 12 decimals (virtual offset 6)
- **States**: OPEN (accepting bets) → CALCULATING (VRF pending) → OPEN, or DEFICIT until covered
- **Compiler**: solc 0.8.34 (contracts pinned, tests/scripts `^0.8.34`)

## Network Configuration

Handled by `script/HelperConfig.s.sol`:
- **Sepolia**: Uses real USDC (`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`)
- **Anvil**: Deploys MockUSDC and VRFCoordinatorV2Mock

## Frontend Stack

React + TypeScript + Vite + Wagmi/Viem. Key files:
- `frontend/src/config.ts` - Contract addresses, bet types, test accounts
- `frontend/src/abis.ts` - Contract ABIs for wagmi hooks
