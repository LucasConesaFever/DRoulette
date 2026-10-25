# DWheel - On-chain Roulette with an LP Vault

European roulette on-chain: players bet USDC credits, Chainlink VRF picks the number, and liquidity providers act as the house through an ERC4626 vault.

> Learning project. It runs on Anvil and Sepolia only and is not meant for mainnet.

## How it works

```
Players ──depositCredits / withdrawCredits (USDC)──▶ Roulette.sol (holds player USDC, credits, bets)
                                                      │  ▲
                        house net win: transfer ──────┘  │ players net win: vault.fundPayout()
                                                      ▼  │
LPs ──ERC4626 deposit / redeem (USDC)──────────────▶ RouletteVault.sol (holds LP USDC only)
```

- **Players** deposit USDC into `Roulette` and get credits 1:1. Bets spend credits, wins are credited automatically, and credits can be withdrawn as USDC at any time.
- **LPs** deposit USDC into `RouletteVault` and get shares. The vault is the house: it gains when players lose and pays when they win, so the share price follows the house's result (expected edge 1/37 ≈ 2.7%).
- **A round**: bets are placed while the roulette is OPEN. The owner calls `spin()`, which requests a random number from Chainlink VRF and closes betting (CALCULATING). The VRF callback settles every bet of the round in one loop and moves the round's net result between Roulette and the vault in a single transfer, then betting reopens.

Full design: [`spec.md`](spec.md).

### Contracts

| Contract | Role |
|---|---|
| `src/Roulette.sol` | Credits custody, bets, VRF request and callback, settlement, refunds |
| `src/RouletteVault.sol` | Plain ERC4626 over USDC for LPs; `totalAssets()` is its USDC balance |
| `src/libraries/RouletteTypes.sol` | Bet types, packed structs, 37-bit number masks, bet validation |
| `src/interfaces/IRouletteLiquidity.sol` | The two Roulette views the vault reads (`lpLocked`, `reservedLiquidity`) |

### Bets

| Bet | Numbers | Pays |
|---|---|---|
| Straight up | one number 0-36 | 35:1 |
| Split | two neighbours in a row or column, or 0 with 1, 2 or 3 | 17:1 |
| Street | the three numbers of a row (e.g. 4-5-6) | 11:1 |
| Corner | four numbers in a square (e.g. 1-2-4-5), or 0-1-2-3 | 8:1 |
| Line | the six numbers of two consecutive rows | 5:1 |
| Dozen / Column | selector 1, 2 or 3 | 2:1 |
| Red, Black, Even, Odd, Low (1-18), High (19-36) | none | 1:1 |

Inside bets are checked against the table layout (rows 1-2-3, 4-5-6, …, 34-35-36); the numbers can come in any order but must be distinct. Zero loses every outside bet.

### Safeguards

- **Exposure limit**: a round's net worst case (every bet winning, minus the stakes) can't exceed `maxExposureBps` (default 10%) of the vault's assets.
- **LP protection**: LP deposits and withdrawals are blocked while a spin is pending or a deficit is open, and withdrawals always leave the open round's worst case in the vault.
- **Bounded callback**: at most `MAX_BETS_PER_ROUND = 70` bets per round, so a round where every bet wins settles within the 2.5M callback gas limit (`test/gas/CallbackGas.t.sol`).
- **Deficit backstop**: if the vault can't pay a round (unreachable under the exposure limit, but handled), Roulette records a deficit, blocks betting, and `coverDeficit()` clears it after a top-up.
- **VRF never answers**: after `vrfTimeout` (minimum 1 hour) the owner can refund the round; every stake is re-credited and a late answer is rejected.
- **Fixed coordinator**: only the VRF coordinator set at deploy time can deliver a result. Roulette implements `rawFulfillRandomWords` itself instead of inheriting `VRFConsumerBaseV2Plus`, whose owner-callable `setCoordinator` would let the owner block a result and refund the round.

## Assumptions and trust model

**USDC**
- Standard ERC20 with 6 decimals: no fee on transfer, no rebasing. Plain transfers are assumed to move exactly the amount sent.
- Circle can pause USDC, blocklist addresses and upgrade the token. A blocklisted player can't withdraw; if Roulette or the vault were blocklisted, deposits, withdrawals and settlement would stop.
- USDC sent straight to Roulette backs no credits; the owner can send it out with `sweepExcess`. USDC sent straight to the vault counts as LP assets (it raises the share price).

**Chain**
- Needs EIP-1153 transient storage (Cancun): the reentrancy guards use `ReentrancyGuardTransient`.
- Chainlink VRF V2.5 must be available. The subscription has to stay funded, or spins wait until the refund timeout.

**Chainlink VRF**
- Trusted for randomness. The winning number is `randomWord % 37` (the modulo bias over 2^256 is negligible).
- The answer is public in the mempool before the callback runs. Betting is closed from `spin()` until settlement, and `emergencyResumeBetting` is blocked while an answer is pending, so nobody can bet on a known result.

**Owner**

The owner (two-step ownership on both contracts) can:
- choose when to `spin()`;
- set the bet limits (`0 < minBet <= maxBet`), spin delay, exposure limit (≤ 100%) and `vrfTimeout` (≥ 1 hour), and the vault's LP capacity;
- pause betting (withdrawals keep working);
- stop betting in an emergency. This locks LPs, but only until `vrfTimeout`: after that anyone can refund the round;
- refund a round whose VRF answer hasn't arrived after `vrfTimeout`. If the answer is merely late, this cancels it;
- send USDC that backs no credits (`sweepExcess`).

The owner can't move player credits or LP assets, change the VRF coordinator, or pick a winning number.

## Setup

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) and Node.js ≥ 18 for the frontend.

```bash
git clone https://github.com/LucasConesaFever/DRoulette.git
cd DRoulette
git submodule update --init   # forge-std, openzeppelin-contracts, chainlink-brownie-contracts, foundry-devops
forge build
forge test
```

## Testing

| Suite | What it covers |
|---|---|
| `test/unit/` | Roulette and vault unit and fuzz tests, including a reference-oracle check of settlement |
| `test/RouletteTypes.t.sol` | Bet validation against a reference table layout (every split pair and street, fuzzed corners and lines), masks |
| `test/invariant/` | Stateful invariants over random player, LP and owner actions: Roulette's USDC exactly backs credits and open stakes, no deficit, vault balance = LP flows + house PnL, reserve coverage, credit conservation |
| `test/gas/CallbackGas.t.sol` | Callback gas benchmark that sizes `MAX_BETS_PER_ROUND` |
| `test/gas/HouseGas.t.sol` | Gas the house pays per round: `spin()` and the callback as VRF bills it |
| `test/fuzz/CryticTester.sol` | The same invariants for Echidna and Medusa |

```bash
forge test                                                    # everything
forge test --isolate --match-path test/gas/CallbackGas.t.sol -vv   # gas benchmark, cold storage
forge coverage --ir-minimum                                   # coverage (stack too deep without it)

medusa fuzz --timeout 300                                     # needs crytic-compile
echidna . --contract CryticTester --config echidna.yaml --timeout 300 --workers 8

mewt run && mewt results                                      # mutation testing (config in mewt.toml)
```

## Deploying

`script/HelperConfig.s.sol` picks the network settings: on Anvil it deploys `MockUSDC` and a VRF V2.5 mock, on Sepolia it uses Circle's test USDC (`0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`) and the Chainlink coordinator.

```bash
# Local: Anvil, then deploy, fund and configure everything (PRIVATE_KEY = an Anvil account key)
anvil
PRIVATE_KEY=<anvil key> forge script script/DeployAndSetupLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

# Sepolia (--account <keystore> or PRIVATE_KEY)
forge script script/DeployRoulette.s.sol --rpc-url $SEPOLIA_RPC_URL --account <keystore> --broadcast
```

`script/Interactions.s.sol` has helpers for the VRF subscription (create, fund, add consumer), LP deposit and withdrawal, player credits, and a `GetVaultInfo` summary.

## Frontend

React + TypeScript + Vite + wagmi/viem, in `frontend/`. Contract addresses live in `frontend/src/config.ts`, ABIs in `frontend/src/abis.ts`.

```bash
cd frontend
npm install
npm run dev     # http://localhost:3000
```

## Security

Found a problem? Open an issue: https://github.com/LucasConesaFever/DRoulette/issues

## License

MIT
