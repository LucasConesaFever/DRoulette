# 🎰 DWheel - Decentralized Roulette Casino

A decentralized on-chain casino roulette project built with Foundry, integrating Chainlink VRF for verifiable randomness and an ERC4626 Vault system for liquidity providers.

> **Current Status**: ✅ Phase 2 Complete - Full vault integration with USDC and credits system

## 📋 Project Description

DWheel is a DeFi application that combines gaming with decentralized finance. Users can deposit USDC to obtain credits and bet on an on-chain casino roulette, while liquidity providers can deposit funds in an ERC4626 vault to earn yields from the house edge.

### System Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                         PHASE 2 ARCHITECTURE                     │
└─────────────────────────────────────────────────────────────────┘

    PLAYERS                    ROULETTE                 VAULT (ERC4626)
       │                          │                           │
       │  1. Deposit USDC         │                           │
       │─────────────────────────────────────────────────────>│
       │                          │                           │
       │  2. Receive Credits      │                           │
       │<─────────────────────────────────────────────────────│
       │                          │                           │
       │  3. Place Bet (credits)  │                           │
       │─────────────────────────>│                           │
       │                          │  4. Record Bet            │
       │                          │──────────────────────────>│
       │                          │                           │
       │                          │  5. Request VRF           │
       │                          │────────────> CHAINLINK    │
       │                          │                           │
       │                          │  6. Random Number         │
       │                          │<──────────── CHAINLINK    │
       │                          │                           │
       │  7. Payout (if win)      │  8. Transfer USDC         │
       │<─────────────────────────│<──────────────────────────│
       │                          │                           │
       │  9. Withdraw Credits     │                           │
       │─────────────────────────────────────────────────────>│
       │ 10. Receive USDC         │                           │
       │<─────────────────────────────────────────────────────│

    LIQUIDITY PROVIDERS
       │
       │  1. Deposit USDC (LP)
       │─────────────────────────────────────────────────────>│
       │  2. Receive Vault Shares (ERC20)                     │
       │<─────────────────────────────────────────────────────│
       │                                                      │
       │  3. Earn Yield (house edge profits)                  │
       │     → Share value increases automatically            │
       │                                                      │
       │  4. Withdraw USDC (burn shares)                      │
       │<─────────────────────────────────────────────────────│
```

## 🏗️ Project Architecture

The project will be developed in **three incremental phases**, each building on the previous one:

### Phase 1: Roulette Logic 🎲

**Objective**: Implement the core roulette logic with a test token.

**Status**: ✅ **COMPLETED**

**Implemented Features**:
- ✅ Complete European roulette logic (numbers 0-36)
- ✅ Number structure, colors (red/black/green)
- ✅ Bet types: straight up, red/black, even/odd, dozens, columns, etc.
- ✅ State system (OPEN/CALCULATING) - bets always open
- ✅ User tracking and statistics system
- ✅ Test token (MockToken) that mints on wins and burns on bets
- ✅ Automatic payout calculation based on bet type
- ✅ Automatic reopening after each spin
- ✅ Chainlink VRF v2 integration for verifiable randomness

**Implemented Contracts**:
- `src/Roulette.sol` - Main roulette contract with VRF integration
- `src/MockToken.sol` - ERC20 test token (deprecated in Phase 2)
- `src/libraries/RouletteTypes.sol` - Library with structures, enums and auxiliary logic
- `src/mocks/VRFCoordinatorV2Mock.sol` - VRF Coordinator mock for testing
- `script/HelperConfig.s.sol` - Network configuration (Sepolia/Anvil)
- `script/Interactions.s.sol` - VRF subscription management scripts

### Phase 2: Decentralized Vault 🏦

**Objective**: Create a vault system for liquidity providers with real USDC integration.

**Status**: ✅ **COMPLETED**

**Implemented Features**:
- ✅ **ERC4626 Vault** for USDC deposits (RouletteVault.sol)
- ✅ **Player Credits System**: Players deposit USDC to receive internal credits for betting
- ✅ **LP Shares System**: Liquidity providers receive vault shares (ERC20) representing their stake
- ✅ **Automatic Yield Distribution**: House edge profits are distributed proportionally to LP shares
- ✅ **Capacity Management**: Maximum vault capacity for LP deposits (configurable by owner)
- ✅ **Dual Accounting System**: 
  - `lpCapital`: Tracks liquidity provider deposits (subject to capacity limits)
  - `playerCredits`: Tracks player deposits (unlimited, not affected by capacity)
- ✅ **Statistics Tracking**: Total bets, wins, losses, and profits
- ✅ **Access Control**: Only authorized Roulette contract can trigger payouts
- ✅ **Emergency Controls**: Pause/unpause functionality for security

**Architecture Changes**:
- ✅ Replaced MockToken with **RouletteVault** (ERC4626 standard)
- ✅ Removed direct token transfers from Roulette.sol
- ✅ Implemented internal credits system for players in the vault
- ✅ Roulette now manages credits mapping internally
- ✅ Vault handles all USDC transfers and accounting

**Contracts**:
- `src/RouletteVault.sol` - ERC4626 vault for USDC deposits and credits management
- `src/mocks/MockUSDC.sol` - 6-decimal USDC mock for testing
- `src/Roulette.sol` - Updated to work with credits system
- `src/libraries/RouletteTypes.sol` - Enhanced with vault-related types

**Key Functions**:

*RouletteVault.sol:*
- `depositCredits(uint256 amount)` - Players deposit USDC to receive credits
- `withdrawCredits(uint256 amount)` - Players withdraw USDC from credits
- `deposit(uint256 assets, address receiver)` - LPs deposit USDC for vault shares (ERC4626)
- `withdraw(uint256 assets, address receiver, address owner)` - LPs withdraw USDC (ERC4626)
- `recordBet(uint256 amount)` - Called by Roulette to track bet statistics
- `recordProfit(uint256 amount)` - Records house edge profit for LP yield
- `recordLoss(uint256 amount)` - Records house losses
- `payout(address player, uint256 amount)` - Transfers winnings to players
- `getMaxBet()` - Returns maximum allowed bet based on available liquidity
- `getAvailableLiquidity()` - Returns liquidity available for payouts

*Roulette.sol:*
- Uses `vault.getMaxBet()` for dynamic bet limits
- Calls `vault.recordBet()` on each bet
- Calls `vault.payout()` for winning bets
- Calls `vault.recordProfit()` or `vault.recordLoss()` based on round results

**Test Coverage**:
- ✅ **82 comprehensive tests** (100% passing)
- ✅ **98.57% vault coverage** (69/70 lines)
- ✅ **93.66% roulette coverage** (133/142 lines)
- ✅ Tests cover: admin functions, LP operations, player credits, capacity management, access control, statistics, edge cases, and ERC4626 compliance

### Phase 3: User Interface 🖥️

**Objective**: Create frontend for protocol interaction.

**Status**: 🔄 **PENDING**

**Planned Features**:
- ⏳ UI for placing bets
- ⏳ Roulette and winning numbers visualization
- ⏳ Dashboard for liquidity providers
- ⏳ Generated yields visualization
- ⏳ Bet history and results
- ⏳ Wallet connection (MetaMask, WalletConnect)

**Technology Stack**:
- Framework: Next.js / React
- Web3: Wagmi / Viem
- UI: TailwindCSS / Shadcn

### Additional Developments ⚙️

**Status**: 🔄 **PENDING**

**Chainlink Automation**:
- ⏳ Automatic execution of roulette rounds
- ⏳ Automatic bet settlement
- ⏳ Periodic metrics updates

**DAO for Governance**:
- ⏳ Voting to change maximum vault capacity
- ⏳ Proposals to adjust protocol parameters
- ⏳ Governance token for voters

## 🛠️ Technologies Used

- **Foundry**: Development and testing framework
- **Solidity**: ^0.8.24
- **Chainlink VRF v2**: Verifiable random number generation
- **Chainlink Automation**: On-chain task automation (planned)
- **ERC4626**: Tokenized vault standard for RouletteVault
- **ERC20**: USDC token standard
- **OpenZeppelin**: Base contracts and security (Ownable, Pausable, ReentrancyGuard)

## 📁 Project Structure

```
DWheel/
├── src/
│   ├── Roulette.sol              # Main roulette contract (Phase 1 & 2)
│   ├── RouletteVault.sol         # ERC4626 vault for USDC and credits (Phase 2)
│   ├── MockToken.sol             # ERC20 test token (deprecated, Phase 1 only)
│   ├── libraries/
│   │   └── RouletteTypes.sol     # Structures, enums and auxiliary logic
│   └── mocks/
│       ├── MockUSDC.sol          # 6-decimal USDC mock for testing
│       └── VRFCoordinatorV2Mock.sol # Chainlink VRF mock
├── test/
│   ├── Roulette.t.sol            # Comprehensive test suite (82 tests)
│   ├── RouletteTypes.t.sol       # Library tests
│   └── mocks/
│       └── LinkToken.sol         # Link token mock for VRF
├── script/
│   ├── DeployRoulette.s.sol      # Deployment script
│   ├── HelperConfig.s.sol        # Network configuration
│   └── Interactions.s.sol        # VRF subscription management
├── lib/                          # External dependencies
│   ├── forge-std/                # Foundry standard library
│   ├── openzeppelin-contracts/  # OpenZeppelin contracts
│   ├── chainlink-brownie-contracts/ # Chainlink contracts
│   └── foundry-devops/           # Deployment utilities
└── cache/                        # Compilation cache
```

**Note on Phases**: The project phases are tracked through Git commits. The code evolves iteratively on the same files rather than creating separate phase folders.

## 🚀 Installation and Setup

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js >= 18 (for frontend in Phase 3)
- Git

### Installation

```bash
# Clone the repository
git clone <repository-url>
cd DWheel

# Install Foundry dependencies
forge install

# Compile contracts
forge build

# Run tests
forge test

# Run tests with coverage
forge coverage
```

## 🔄 Phase 2 Architecture Changes

### Key Design Decisions

1. **ERC4626 Standard**: RouletteVault implements the ERC4626 tokenized vault standard, providing:
   - Standardized interface for deposits/withdrawals
   - Automatic share calculation and management
   - Compatibility with DeFi ecosystem tools

2. **Credits System**: Players don't bet USDC directly. Instead:
   - Players deposit USDC → receive internal credits (1:1)
   - Roulette manages credits mapping internally
   - Players withdraw credits → receive USDC back
   - Eliminates need for token approvals on every bet

3. **Dual Accounting**:
   - `lpCapital`: Tracks LP deposits (subject to MAX_VAULT_CAPACITY)
   - `playerCredits`: Tracks player deposits (unlimited)
   - Prevents LP capacity limits from blocking player deposits

4. **Automatic Yield Distribution**:
   - House edge profits increase vault's total assets
   - Share value automatically increases for all LPs
   - No manual claim needed - yield is realized on withdrawal

5. **Dynamic Max Bet**:
   - Max bet = available liquidity × maxBetMultiplier
   - Prevents single bet from bankrupting the vault
   - Adjusts automatically based on current liquidity

### Removed Components

- ❌ **MockToken.sol**: Replaced by USDC + credits system
- ❌ **RoulettePhase2.t.sol**: Consolidated into Roulette.t.sol
- ❌ **Direct token transfers in Roulette**: All funds managed by vault
- ❌ **RouletteBank concept**: Simplified to direct Roulette ↔ Vault interaction

### Migration from Phase 1 to Phase 2

**Before (Phase 1)**:
```solidity
// MockToken minted/burned on bets
mockToken.burn(msg.sender, betAmount);
mockToken.mint(msg.sender, payout);
```

**After (Phase 2)**:
```solidity
// Credits managed by Roulette, USDC by Vault
credits[msg.sender] -= betAmount;
vault.recordBet(betAmount);
// ...on win...
vault.payout(player, winAmount);
credits[player] += winAmount;
```

## 🧪 Testing

The project includes a comprehensive test suite with 82 tests covering all functionality:

```bash
# Run all tests
forge test

# Tests with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/Roulette.t.sol

# Run specific test
forge test --match-test testVault_LPYieldAccumulation

# Tests with gas report
forge test --gas-report

# Coverage report
forge coverage

# Coverage for specific file
forge coverage --match-path test/Roulette.t.sol
```

### Test Categories

**Phase 1 Tests (58 tests)**:
- ✅ Constructor and initialization
- ✅ Bet placement (all bet types)
- ✅ Bet validations (min/max, invalid numbers, etc.)
- ✅ Spin mechanics and VRF integration
- ✅ Payout calculations (straight up, red/black, etc.)
- ✅ State transitions (OPEN ↔ CALCULATING)
- ✅ Multiple rounds and players
- ✅ Emergency controls (pause/unpause)
- ✅ Owner functions (setMinBet, setMaxBet, etc.)

**Phase 2 Tests (24 new tests)**:
- ✅ **Player Credits**: deposit, withdraw, bet with credits
- ✅ **LP Operations**: deposit, mint, withdraw, redeem (ERC4626)
- ✅ **Yield Distribution**: profit accumulation, share value growth
- ✅ **Capacity Management**: LP limits, player credits unlimited
- ✅ **Access Control**: onlyRoulette modifiers, onlyOwner checks
- ✅ **Statistics**: recordBet, recordProfit, recordLoss tracking
- ✅ **View Functions**: getAvailableLiquidity, getMaxBet, getVaultStats
- ✅ **Edge Cases**: zero amounts, insufficient balance, roulette not set
- ✅ **ERC4626 Compliance**: asset(), totalAssets(), preview functions
- ✅ **Integration**: full game flow with vault, multiple LPs sharing yield

### Coverage Report

```
| File                          | % Lines        | % Statements   | % Branches    | % Funcs       |
|-------------------------------|----------------|----------------|---------------|---------------|
| src/Roulette.sol              | 93.66%         | 94.12%         | 83.33%        | 87.50%        |
| src/RouletteVault.sol         | 98.57%         | 98.65%         | 92.31%        | 100.00%       |
| src/libraries/RouletteTypes.sol | 48.42%       | 42.73%         | 18.18%        | 44.44%        |
```

**Note**: RouletteTypes.sol has lower coverage because it contains view/pure helper functions that are tested indirectly through Roulette.sol usage.

## 📜 Deployment Scripts

```bash
# Deploy on testnet
forge script script/DeployRoulette.s.sol --rpc-url $RPC_URL --broadcast

# Deploy on mainnet
forge script script/DeployRoulette.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify

# Verify contracts
forge verify-contract <address> <contract> --chain <chain-id> --etherscan-api-key $ETHERSCAN_KEY
```

## 🎮 Protocol Usage

### For Players (Bettors)

1. **Deposit USDC for Credits**:
   ```solidity
   usdc.approve(address(vault), amount);
   vault.depositCredits(amount);
   ```

2. **Place Bet**:
   ```solidity
   uint8[] memory numbers = new uint8[](1);
   numbers[0] = 7; // Bet on number 7
   roulette.placeBet(RouletteTypes.BetType.STRAIGHT_UP, numbers, betAmount);
   ```

3. **Wait for Spin & VRF Result**: The owner calls `spin()` and Chainlink VRF provides randomness

4. **Automatic Payout**: If you win, funds are automatically credited to your account

5. **Withdraw Credits**:
   ```solidity
   vault.withdrawCredits(amount);
   ```

### For Liquidity Providers (LPs)

1. **Deposit USDC to Vault**:
   ```solidity
   usdc.approve(address(vault), amount);
   vault.deposit(amount, lpAddress); // Receive vault shares
   ```

2. **Earn Yields**: House edge profits automatically increase share value

3. **Monitor Performance**:
   ```solidity
   vault.getVaultStats(); // View total bets, wins, losses, profits
   vault.previewRedeem(shares); // Check current USDC value of shares
   ```

4. **Withdraw Funds**:
   ```solidity
   vault.withdraw(assets, receiver, owner); // Burn shares, receive USDC
   ```

## 🔒 Security

- [x] **Comprehensive tests**: 82 tests with 98.57% vault coverage and 93.66% roulette coverage
- [x] **ReentrancyGuard**: Applied on critical vault and roulette functions
- [x] **Access control**: Ownable for admin functions, only Roulette can call vault payouts
- [x] **Pausable**: Emergency pause functionality for both contracts
- [x] **Input validations**: Extensive validation on all user inputs
- [x] **ERC4626 Standard**: Industry-standard vault implementation
- [x] **Chainlink VRF**: Verifiable randomness for fair spins
- [ ] **Contract audit**: Professional security audit pending

## 📊 Key Parameters

### Roulette
- **Numbers**: 0-36 (European roulette)
- **House Edge**: ~2.7% (1/37 from the zero)
- **Minimum bet**: Configurable by owner (default: 1 USDC)
- **Maximum bet**: Dynamic, based on vault available liquidity × multiplier
- **Bet Types**: Straight Up (35:1), Red/Black (1:1), Even/Odd (1:1), Dozens (2:1), Columns (2:1), etc.
- **State Management**: OPEN → CALCULATING (during VRF) → OPEN

### RouletteVault
- **Standard**: ERC4626 (Tokenized Vault)
- **Asset**: USDC (6 decimals)
- **LP Capacity**: Configurable maximum (default: 10,000,000 USDC)
- **Player Credits**: Unlimited, not subject to capacity restrictions
- **Share Value**: Increases with house edge profits
- **Yield Distribution**: Automatic, proportional to shares owned
- **Max Bet Multiplier**: Configurable (default: 0.01 = 1% of available liquidity)

## 📡 Events

### Roulette Events
```solidity
event BetPlaced(uint256 indexed roundId, address indexed player, uint256 betId, RouletteTypes.BetType betType, uint256 amount);
event SpinInitiated(uint256 indexed roundId, uint256 requestId);
event SpinResult(uint256 indexed roundId, uint8 winningNumber);
event PayoutProcessed(uint256 indexed roundId, address indexed player, uint256 betId, uint256 payout);
event RoundCompleted(uint256 indexed roundId, uint8 winningNumber, uint256 totalBets, uint256 totalPayouts);
```

### RouletteVault Events (ERC4626 Standard)
```solidity
event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
event CreditsDeposited(address indexed player, uint256 amount);
event CreditsWithdrawn(address indexed player, uint256 amount);
event BetRecorded(uint256 amount);
event ProfitRecorded(uint256 amount);
event LossRecorded(uint256 amount);
event MaxCapacityUpdated(uint256 newMaxCapacity);
event RouletteUpdated(address indexed newRoulette);
```

## 🗺️ Roadmap

### Phase 1: Roulette Fundamentals ✅ COMPLETED
- [x] Basic roulette logic with MockToken
- [x] State system (OPEN/CALCULATING)
- [x] All bet types and validations
- [x] Chainlink VRF integration
- [x] Complete tests (58 tests passing)
- [x] Emergency controls (pause/unpause)
- [x] **Commit**: "Phase 1 Complete"

### Phase 2: Vault and Real Economy ✅ COMPLETED
- [x] ERC4626 Vault implementation (RouletteVault.sol)
- [x] USDC integration (6-decimal MockUSDC for testing)
- [x] Player credits system (deposit/withdraw USDC)
- [x] LP shares system with automatic yield distribution
- [x] Dual accounting (lpCapital vs playerCredits)
- [x] Capacity management for LPs
- [x] Statistics tracking (bets, wins, losses, profits)
- [x] Access control (only Roulette can trigger payouts)
- [x] Dynamic max bet based on available liquidity
- [x] Complete tests (82 tests, 98.57% vault coverage)
- [x] Integration tests (full game flow with vault)
- [x] **Commit**: "Phase 2 Complete"

### Phase 3: Frontend and Interaction 🔄 PENDING
- [ ] UI development (Next.js/React)
- [ ] Web3 integration (Wagmi/Viem)
- [ ] Player dashboard (credits, bet history)
- [ ] LP dashboard (shares, yields, statistics)
- [ ] Roulette visualization (spinning wheel, results)
- [ ] Wallet connection (MetaMask, WalletConnect)
- [ ] **Commit**: "Phase 3 Complete"

### Additional Developments 🔄 PENDING
- [ ] Chainlink Automation (automatic spins)
- [ ] DAO and governance (parameter adjustments)
- [ ] Security audit
- [ ] Mainnet deployment

## 📝 License

MIT

## 👥 Contributing

Contributions are welcome. Please:

1. Fork the project
2. Create a branch for your feature
3. Commit your changes
4. Push to the branch
5. Open a Pull Request

## 📞 Contact

For questions or suggestions about the project, please open an issue.

---

**Note**: This project is under active development. Contracts have not been audited and should not be used in production without a professional audit.

