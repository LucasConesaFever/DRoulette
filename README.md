# 🎰 DWheel - Decentralized Roulette Casino

A decentralized on-chain casino roulette project built with Foundry, integrating Chainlink VRF for verifiable randomness and a Vault system with DAO governance.

## 📋 Project Description

DWheel is a DeFi application that combines gaming with decentralized finance. Users can bet tokens (USDT/USDC) on an on-chain casino roulette, while liquidity providers can deposit funds in a vault to earn yields from the house edge.

## 🏗️ Project Architecture

The project will be developed in **three incremental phases**, each building on the previous one:

### Phase 1: Roulette Logic 🎲

**Objective**: Implement the core roulette logic with a test token.

**Current Status**:
- ✅ Complete European roulette logic (numbers 0-36)
- ✅ Number structure, colors (red/black/green)
- ✅ Bet types: straight up, red/black, even/odd, dozens, columns, etc.
- ✅ State system (OPEN/CALCULATING) - bets always open
- ✅ User tracking and statistics system
- ✅ Test token (MockToken) that mints on wins and burns on bets
- ✅ Automatic payout calculation based on bet type
- ✅ Automatic reopening after each spin
- ⏳ Chainlink VRF integration (in development)

**Implemented Contracts**:
- `src/Roulette.sol` - Main roulette contract
- `src/MockToken.sol` - ERC20 test token
- `src/libraries/RouletteTypes.sol` - Library with structures, enums and auxiliary logic

### Phase 2: Decentralized Vault 🏦

**Objective**: Create a vault system for liquidity providers.

**Features**:
- ✅ ERC4626 Vault for USDC/USDT deposits
- ✅ Yield system for liquidity providers
- ✅ Tracking of roulette wins/losses
- ✅ Automatic payouts to winning bettors from vault
- ✅ Yield claiming system for LPs
- ✅ Variable maximum vault capacity
- ✅ Shares mechanism for proportional distribution
- ✅ Intermediate contract (RouletteBank) for fund management

**Contracts**:
- `RouletteVault.sol` - Main vault (ERC4626)
- `RouletteBank.sol` - Intermediary between roulette and vault
- `YieldDistributor.sol` - Yield distribution management

### Phase 3: User Interface 🖥️

**Objective**: Create frontend for protocol interaction.

**Features**:
- ✅ UI for placing bets
- ✅ Roulette and winning numbers visualization
- ✅ Dashboard for liquidity providers
- ✅ Generated yields visualization
- ✅ Bet history and results
- ✅ Wallet connection (MetaMask, WalletConnect)

**Technology Stack**:
- Framework: Next.js / React
- Web3: Wagmi / Viem
- UI: TailwindCSS / Shadcn

### Additional Developments ⚙️

**Chainlink Automation**:
- Automatic execution of roulette rounds
- Automatic bet settlement
- Periodic metrics updates

**DAO for Governance**:
- Voting to change maximum vault capacity
- Proposals to adjust protocol parameters
- Governance token for voters

## 🛠️ Technologies Used

- **Foundry**: Development and testing framework
- **Solidity**: ^0.8.20
- **Chainlink VRF v2**: Verifiable random number generation
- **Chainlink Automation**: On-chain task automation
- **ERC20**: Tokens (USDC/USDT)
- **ERC4626**: Vault standard
- **OpenZeppelin**: Base contracts and security

## 📁 Project Structure

```
DWheel/
├── src/
│   ├── Roulette.sol         # Main roulette contract
│   ├── MockToken.sol        # ERC20 test token (temporary)
│   ├── libraries/           # Auxiliary libraries
│   │   └── RouletteTypes.sol
│   ├── interfaces/          # Interfaces (Chainlink VRF, etc.)
│   └── mocks/               # Mock contracts for testing
├── test/
│   ├── Roulette.t.sol       # Main contract tests
│   ├── RouletteTypes.t.sol  # Library tests
│   ├── integration/         # Integration tests
│   └── mocks/               # Testing mocks
├── script/
│   ├── DeployRoulette.s.sol # Deployment script
│   └── utils/               # Deployment utilities
├── frontend/                # Web application (Phase 3)
└── lib/                     # External dependencies
```

**Note on Phases:** The three project phases are distinguished through Git commits, not by folder structure. The code evolves on the same files, allowing for iterative and clean development.

## 🚀 Installation and Setup

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js >= 18 (for frontend)
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

## 🧪 Testing

```bash
# Run all tests
forge test

# Tests with verbosity
forge test -vvv

# Specific tests
forge test --match-contract RouletteTest
forge test --match-test test_PlaceBet

# Tests with gas report
forge test --gas-report

# Coverage
forge coverage
```

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

### For Bettors

1. Approve tokens to the roulette contract
2. Place bet by selecting type and amount
3. Wait for VRF result
4. Receive payouts automatically if you win

### For Liquidity Providers

1. Deposit USDC/USDT in the vault
2. Receive vault shares
3. Monitor generated yields
4. Claim yields or withdraw funds

## 🔒 Security

- [ ] Contract audit
- [x] Comprehensive tests (>90% coverage)
- [x] ReentrancyGuard on critical functions
- [x] Access control with Ownable/AccessControl
- [x] Pausable for emergencies
- [x] Input validations

## 📊 Key Parameters

### Roulette
- Numbers: 0-36 (European roulette)
- House Edge: ~2.7%
- Minimum bet: Configurable
- Maximum bet: Based on available liquidity

### Vault
- Maximum capacity: Variable (governance)
- Withdrawal fee: TBD
- Lock period: TBD

## 🗺️ Roadmap

### Phase 1: Roulette Fundamentals
- [x] Basic roulette logic with MockToken
- [x] State system (OPEN/CALCULATING)
- [x] Bet types and validations
- [ ] Chainlink VRF integration
- [ ] Complete tests
- [ ] Testnet deployment
- [ ] **Commit:** "Phase 1 Complete"

### Phase 2: Vault and Real Economy
- [ ] ERC4626 Vault implementation
- [ ] USDC/USDT integration
- [ ] Yield system for LPs
- [ ] RouletteBank (intermediary)
- [ ] Liquidity limits
- [ ] Complete tests
- [ ] Testnet deployment
- [ ] **Commit:** "Phase 2 Complete"

### Phase 3: Frontend and Interaction
- [ ] UI development (Next.js)
- [ ] Web3 integration (Wagmi/Viem)
- [ ] Player dashboard
- [ ] LP dashboard
- [ ] Roulette visualization
- [ ] **Commit:** "Phase 3 Complete"

### Additional Developments
- [ ] Chainlink Automation
- [ ] DAO and governance
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

