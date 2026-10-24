# Spec: Move player funds from the Vault into Roulette

Status: **Draft** · Author: Lucas Conesa · Date: 2026-10-24

## 1. Problem

Today `RouletteVault` holds **all** USDC in one balance: LP liquidity and the USDC players deposit for credits. Because of that:

- The vault cannot use the standard ERC4626 `totalAssets() = balanceOf(this)`. Instead it keeps shadow accounting (`lpCapital`, `totalProfit`, `totalLoss`, `_reduceProportionally`) so that player credits are left out of the share price. This is the most complex and fragile part of the codebase.
- Player-facing functions (`depositCredits`, `withdrawCredits`) live in the vault, but the credit ledger lives in Roulette. This creates a circular dependency (Vault → `Roulette.addCredits/removeCredits`, Roulette → `vault.payout/record*`).
- `getAvailableLiquidity()` and `getMaxBet()` use `balanceOf(vault)`, which includes player money. So the vault looks more solvent than it is, and players' own deposits can back other players' winnings.
- `vault.payout()` moves no tokens. It only checks the balance and records stats. Winnings become credits whose backing USDC stays in the vault and mixes with LP funds.
- The VRF callback is expensive and grows with every bet (measured: ~101k fixed + ~46.5k per losing bet + ~75k per winning bet). With the configured `callbackGasLimit = 500_000`, a round with more than ~8 losing or ~4 winning bets runs out of gas. The callback then reverts, Chainlink does not retry, and the round stays stuck in CALCULATING.

## 2. Goal

- **The vault is a plain ERC4626 that only LPs use.** Its USDC balance is LP money. Share price = `balanceOf(vault) / totalSupply`.
- **Roulette custodies all player USDC.** Its balance backs the credit ledger plus the stakes of the round in progress.
- USDC moves between the two contracts only at round settlement, as one net transfer.
- The VRF callback is cheap per bet and bounded, so it always fits in `callbackGasLimit`.

### Non-goals

- Changes to game rules, bet types, VRF integration or the round state machine (except the new `DEFICIT` state, §5.7).
- Turning credits into an ERC20 token.
- Claim-based payouts and per-number payout tables (evaluated and rejected, see §9).
- Upgradeability or proxies. Contracts are redeployed.

## 3. Target architecture

```
Players ──deposit/withdraw USDC──▶ Roulette (holds player USDC, credit ledger, bets)
                                       │  ▲
              net loss of players ─────┘  │ net win of players
              (USDC → vault)              │ (vault → USDC, pulled by Roulette)
                                       ▼  │
LPs ──deposit/redeem (ERC4626)──▶ RouletteVault (holds LP USDC only)
```

Calls go Roulette → Vault. The vault only **reads** two views from Roulette to limit LP deposits/withdrawals (§5.6). It never changes Roulette state.

## 4. RouletteVault (new)

### 4.1 What it keeps

- ERC4626 over USDC, `Ownable`, `ReentrancyGuard`.
- `maxCapacity` checked against `totalAssets()` through the `maxDeposit` / `maxMint` overrides. This replaces the `lpCapital` check. The standard ERC4626 limit functions then enforce it, so `deposit`/`mint` need no override.
- `roulette` address, set once by the owner.
- Default `totalAssets()` (`balanceOf(this)`). Profit and loss show up in the share price automatically.

### 4.2 What it removes

| Removed | Reason |
|---|---|
| `lpCapital`, `totalProfit`, `totalLoss`, `_reduceProportionally` | Not needed once the balance is LP-only |
| `deposit`/`mint`/`withdraw`/`redeem` overrides | Limits move to the `max*` functions |
| `depositCredits`, `withdrawCredits`, `IRouletteCredits` | Moved to Roulette |
| `payout`, `recordBet`, `recordProfit`, `recordLoss` | Replaced by a single `fundPayout` |
| `totalBetsPlaced`, `totalPayouts` stats | Moved to Roulette (§5.9) |
| `getVaultStats`, `getLpCapacityInfo`, `getAvailableLiquidity`, `getMaxBet` | Replaced by standard ERC4626 views + Roulette views |

### 4.3 New surface

```solidity
/// Roulette pulls USDC to cover a round where players won more than they staked.
function fundPayout(uint256 amount) external onlyRoulette nonReentrant;
// → safeTransfer(asset, roulette, amount); emit PayoutFunded(amount)
```

Profit needs no function: Roulette does a plain `safeTransfer(asset, vault, amount)`, and the share price goes up.

LP limits read Roulette (§5.6):

```solidity
interface IRouletteLiquidity {
    function lpLocked() external view returns (bool);          // true while CALCULATING or DEFICIT
    function reservedLiquidity() external view returns (uint256); // net worst-case exposure of the open round
}

maxDeposit / maxMint      → 0 if lpLocked(), else capacity left
maxWithdraw / maxRedeem   → 0 if lpLocked(), else capped so totalAssets() stays >= reservedLiquidity()
```

The owner can override the lock in an emergency (`setLpLockOverride(bool)`), to pair with `emergencyResumeBetting`.

### 4.4 Inflation / donation protection

With `totalAssets = balanceOf`, the vault is exposed to the classic first-depositor donation attack. Mitigation: override `_decimalsOffset()` (OZ virtual shares, e.g. `6`) and/or seed the vault with a small dead deposit at deploy time.

## 5. Roulette (changes)

### 5.1 Custody

- `depositCredits(uint256 amount)`: `safeTransferFrom(player, this, amount)`, `credits += amount`. `nonReentrant`.
- `withdrawCredits(uint256 amount)`: `credits -= amount`, `safeTransfer(player, amount)`. `nonReentrant`. Allowed in every state, including CALCULATING (stakes are already debited) and DEFICIT (first come, first served, §5.7).
- `addCredits` / `removeCredits` / `OnlyVault` are removed.
- Roulette needs an `IERC20 usdc` reference, read from `vault.asset()` in the constructor (`immutable`).

### 5.2 Bet storage (one slot per bet)

The callback cost is mostly storage reads and writes per bet. The bet is packed into a single slot, and the bet numbers become a bitmask:

```solidity
struct Bet {
    address player;     // 20 bytes
    BetType betType;    // 1 byte
    uint40 numbersMask; // 5 bytes: bit n set = bet covers number n (37 bits used)
    uint48 amount;      // 6 bytes: max ~281M USDC per bet (6 decimals)
}                       // = 32 bytes, one slot
```

- `placeBet` keeps its current signature (`uint8[] numbers`): it validates the numbers as today, then builds the mask. The frontend call doesn't change.
- `checkWin` becomes `(numbersMask >> winningNumber) & 1`.
- Removed from `Bet`: `numbers` array, `timestamp`, `settled`, `won`, `payout`. Settled = `rounds[roundId].completed`. Won/payout are derived by a view `getBetResult(betId)` from the round's winning number. The bet time is in the `BetPlaced` event.
- Bets of a round have contiguous IDs (only one round is open at a time). So `Round` stores `firstBetId` and `lastBetId`, and the `roundBets` array is removed. This saves one array write per bet and one read per bet in the callback. `getRoundBets(roundId)` stays as a view that returns the range.
- `placeBet` requires `amount <= type(uint48).max` (already implied by `maxBet`).

### 5.3 Settlement: one loop

`fulfillRandomWords` saves the winning number and runs **one loop** over the round's bets:

```
int256 net = 0;                       // > 0: players won overall, < 0: house won
for each bet in [firstBetId, lastBetId]:
    if won:
        payout = amount * (multiplier + 1)
        credits[player] += payout
        playerStats[player].totalWon += amount * multiplier
        net += amount * multiplier    // winnings only; the stake is already in Roulette
        emit BetWon(betId, player, payout)
    else:
        net -= amount                 // no storage write for losers
totalCredits += sum of payouts        // written once after the loop
```

Then the net settlement with the vault:

- `net < 0` → `usdc.safeTransfer(vault, -net)`
- `net > 0` and the vault can cover it → `vault.fundPayout(net)`
- `net > 0` and the vault can't cover it → deficit backstop (§5.7)
- `net == 0` → no transfer

Then: `round.completed = true`, house stats updated (§5.9), `currentRoundId++`, state OPEN, `SpinCompleted` emitted.

Winners are credited **before** the vault check. The exposure limit (§5.5) and LP reservation (§5.6) make a shortfall practically impossible, so the callback doesn't need a separate pass to compute the total first.

### 5.4 Solvency invariant (Roulette)

```
usdc.balanceOf(roulette) >= totalCredits + stakes of the open round   (state OPEN / CALCULATING)
usdc.balanceOf(roulette) + deficit >= totalCredits                      (state DEFICIT)
```

This must hold after every external call. It is the main property to fuzz / invariant-test.

### 5.5 Exposure limit

- Track `roundMaxExposure`: for each bet, add `amount * (multiplier + 1)`. This is a conservative upper bound: it assumes every bet wins.
- In `placeBet`, require `roundMaxExposure - roundTotalBets <= vault.totalAssets() * maxExposureBps / 10_000`. Revert with `ExposureLimitExceeded()`.
- `maxExposureBps` defaults to `1_000` (10%). The owner can change it with `setMaxExposureBps(uint256)` (must be `<= 10_000`).
- Keep the fixed `minBet`/`maxBet` as an extra per-bet cap.

### 5.6 LP protection

Two problems, one mechanism (the views in §4.3):

1. **Front-running.** Once `fulfillRandomWords` is in the mempool, the outcome is public. An LP could withdraw before a player win, or deposit before a house win. → `lpLocked()` returns true while state is CALCULATING (and DEFICIT), so all LP deposits/withdrawals are capped to 0.
2. **Withdrawing the reserve.** Bets are checked against vault TVL when placed (§5.5). If LPs then withdraw before `spin()`, the round could exceed what the vault holds. → `reservedLiquidity()` returns `roundMaxExposure - roundTotalBets` for the open round, and `maxWithdraw`/`maxRedeem` keep that amount in the vault.

Together with §5.5, a round's worst-case net payout is always available in the vault when it settles.

No extra storage writes: Roulette already tracks the state and the round exposure. The vault reads them.

### 5.7 Deficit backstop

Only reachable if the safeguards above are bypassed (owner raises `maxExposureBps` mid-round, uses the emergency LP unlock, etc.). The callback must not revert, so:

1. Pull what the vault has: `pulled = usdc.balanceOf(vault)`, `vault.fundPayout(pulled)`.
2. Record `deficit = net - pulled`, set state `DEFICIT`, emit `DeficitRecorded(roundId, deficit)`. The round still completes; players are already credited.

While in `DEFICIT`:

- `placeBet` and `spin` revert.
- LP deposits/withdrawals are locked (`lpLocked()`).
- `withdrawCredits` stays open, first come, first served. Roulette holds less USDC than `totalCredits`, so once its balance runs out, the remaining withdrawals revert (`InsufficientRouletteBalance()`) until `coverDeficit()` brings USDC back. This is accepted: the case is very unlikely, and blocking would trap every player's funds.
- To unfreeze, someone sends USDC to the vault with a plain transfer (owner or treasury top-up). LP `deposit` stays blocked: new shares would be minted before the loss is paid, pushing part of it onto the new LP.

`coverDeficit()` (permissionless): pulls `min(deficit, usdc.balanceOf(vault))` from the vault. When `deficit` reaches 0, state goes back to OPEN and the LP lock lifts. Emits `DeficitCovered(amount, remaining)`.

### 5.8 VRF never responds (refund)

Separate failure from §5.7: Chainlink never calls back, so there is no winning number. `refundRound()` (`onlyOwner`, only when `state == CALCULATING` and `block.timestamp - spinRequestedAt >= vrfTimeout`):

- Re-credits each bet's `amount` and rolls back `playerStats.totalWagered` / `totalBets` for those bets.
- Deletes the `requestId → roundId` mapping, so a late VRF answer reverts with `InvalidRequestId` instead of settling a refunded round.
- Marks the round completed (no winning number), increments `currentRoundId`, sets state to OPEN. Emits `RoundRefunded(roundId)`.
- `vrfTimeout` is owner-configurable, default 1 hour.

### 5.9 Stats

Kept on-chain, but arranged so losing bets need no write in the callback:

- **Per player** (`playerStats`): `totalBets`, `totalWagered`, `lastPlayedTimestamp` are written in `placeBet` (as today). `totalWon` (winnings, without stake) is written in the callback for winners only. `totalLost` is no longer stored; `getPlayerStats` derives it as `totalWagered − stakes of won bets − stakes in the open round`. To make that exact, the callback also adds the stake to a `totalWonStakes` field for winners (same slot pattern, no extra cost for losers).
- **Global, in Roulette**: `totalWagered`, `totalPaidOut`, `houseNetPnl` (`int256`), updated once per round in the callback. View `getHouseStats()`.
- LP-side numbers (TVL, share price) come from standard ERC4626 views on the vault.

### 5.10 Callback gas budget

Estimated per-bet cost in the callback after §5.2–§5.9 (to be confirmed with a benchmark during implementation):

| | Today (measured) | New (estimated) |
|---|---|---|
| Fixed per round | ~101k | ~100k |
| Losing bet | ~46.5k | ~3k (one slot read + mask check) |
| Winning bet | ~75k | ~12–30k (read + credits + stats + event) |
| Round of 50 bets, 10 winners | ~2.7M | ~0.3–0.5M |

- Add a constant `MAX_BETS_PER_ROUND` (no setter). `placeBet` reverts with `RoundFull()` past it.
- Its value comes from the benchmark: the largest number of bets that all win and still settle within `callbackGasLimit`, with a safety margin. Expected around 75.
- `callbackGasLimit` stays `immutable`. Deploy scripts raise it from `500_000` to `2_500_000` (Chainlink's usual maximum).
- A test asserts that a full round of `MAX_BETS_PER_ROUND` winning bets fits in `callbackGasLimit`.

Why a cap is needed: without one, a busy round could run out of callback gas and get stuck until the refund timeout. Worse, an attacker could place hundreds of minimum bets to make every round fail, then get their stakes back through the refund, paying only gas. With the cap, filling a round costs `MAX_BETS_PER_ROUND` real bets that can lose.

## 6. Events

- Roulette: `CreditsDeposited(player, amount)`, `CreditsWithdrawn(player, amount)`, `BetWon(betId, player, payout)` (replaces `BetSettled`; losers emit nothing), `RoundSettled(roundId, totalBets, totalPayout, int256 netToPlayers)`, `DeficitRecorded(roundId, deficit)`, `DeficitCovered(amount, remaining)`, `RoundRefunded(roundId)`, `MaxExposureBpsUpdated`, `VrfTimeoutUpdated`.
- Vault: `PayoutFunded(amount)`, `LpLockOverrideUpdated(bool)`, `RouletteSet`, `MaxCapacityUpdated`. Profit has no event (plain transfer).

## 7. Impact on other code

| Area | Change |
|---|---|
| `src/libraries/RouletteTypes.sol` | New packed `Bet`, `Round` gets `firstBetId`/`lastBetId`, `RouletteState.DEFICIT`, `numbersToMask()`, mask-based `checkWin`. `validateBet` unchanged. |
| `test/Roulette.t.sol` | ~66 call sites to `depositCredits`/vault stats. Rewrite the credit tests against Roulette. Replace the `lpCapital`/profit/loss tests with share-price tests. Add: invariant test for §5.4; LP reservation and lock; deficit path; refund path; gas test for a full round. |
| `test/RouletteTypes.t.sol` | Add mask conversion tests; `checkWin` tests switch to masks. |
| `script/DeployAndSetupLocal.s.sol`, `Interactions.s.sol`, `DeployRoulette.s.sol`, `HelperConfig.s.sol` | Approve/deposit credits against Roulette. Replace `lpCapital`/`getVaultStats`/`getMaxBet` logs. New `callbackGasLimit` default. |
| `frontend/src/App.tsx`, `abis.ts` | `approveIfNeeded` spender + `depositCredits`/`withdrawCredits` target → Roulette address. Regenerate ABIs (`getBet` shape changes; use `getBetResult` and events for bet history). Vault panel → `totalAssets`, `convertToAssets(1e6)`, `maxWithdraw`. Show a banner in DEFICIT. |
| `CLAUDE.md` | Update the architecture diagram and "Dual Accounting" pattern. Fix the stale `maxBetMultiplier` reference (no such parameter exists in code). |
| Repo setup | `lib/forge-std` and `lib/openzeppelin-contracts` submodules are not initialized; run `git submodule update --init` before building. |
| Deployments | Sepolia: fresh deploy, no migration (testnet). |

## 8. Acceptance criteria

- [ ] `RouletteVault` has no player-facing functions and no custom asset accounting. `totalAssets()` is not overridden.
- [ ] `usdc.balanceOf(vault)` changes only through LP deposit/withdraw and round settlement.
- [ ] Solvency invariant §5.4 holds under fuzzing (deposit/withdraw/bet/spin/fulfill/LP sequences).
- [ ] Bets that push round exposure over `maxExposureBps` of vault TVL revert; the owner can change the limit.
- [ ] LP withdrawals can't take the vault below `reservedLiquidity()`; all LP actions are capped to 0 during CALCULATING and DEFICIT.
- [ ] `fulfillRandomWords` never reverts because of vault funds: on a shortfall it records a deficit, and `coverDeficit()` clears it after a top-up.
- [ ] A round with `MAX_BETS_PER_ROUND` bets that all win settles within `callbackGasLimit`.
- [ ] The owner can refund a round after `vrfTimeout`, and a late VRF answer for it reverts.
- [ ] `getHouseStats()` and `getPlayerStats()` match the sum of settled bets.
- [ ] All game-rule tests (bet types, payouts, validation) pass with the mask-based bets.
- [ ] Frontend can deposit/withdraw credits and LP deposit/redeem against the new contracts on Anvil.

## 9. Decisions

| Topic | Decision |
|---|---|
| Exposure bound | Conservative (sum of max payouts), owner-modifiable limit (§5.5) |
| Round risk limit | `maxExposureBps = 1_000` (10%), owner-modifiable |
| LP protection | Lock during CALCULATING/DEFICIT + reserve the open round's exposure (§5.6) |
| Stats | Kept on-chain; losing bets need no write in the callback (§5.9) |
| Payout model | Credit winners automatically in the callback. Claims were evaluated: the callback still needs the loop for the net amount, so they only save the winners' credit writes, while each winner pays ~50k+ for a claim tx and `totalLost` can't be tracked |
| Per-number payout table | Rejected: extra writes on every bet, only useful together with claims |
| Settlement loop | One loop; winners are credited before the vault check (§5.3) |
| Vault shortfall | Pull what's available, record a deficit, freeze bets/spins until covered (§5.7) |
| Withdrawals during DEFICIT | Allowed, first come, first served (§5.7) |
| VRF timeout refund | Kept, `vrfTimeout` default 1 hour (§5.8) |
| Bets per round | Constant `MAX_BETS_PER_ROUND`, value from the benchmark; `callbackGasLimit` stays immutable at `2_500_000` (§5.10) |

## 10. Open questions

1. **`MAX_BETS_PER_ROUND` value**: set from the benchmark during implementation (expected ~75).

## 11. Future upgrade: settlement outside the VRF callback

Not part of this refactor. It removes the bet cap if rounds ever need more bets than one callback can settle.

**Idea:** `fulfillRandomWords` only saves the winning number. An external process (a keeper) watches the chain, sees the number saved, and settles the bets in one or more transactions.

**Flow:**

1. `spin()` → state CALCULATING, VRF request (unchanged).
2. `fulfillRandomWords` → saves `winningNumber`, sets state `SETTLING`, emits `WinningNumberSaved(roundId, winningNumber)`. Fixed cost, no loop, so the callback gas limit stops mattering.
3. Keeper listens for `WinningNumberSaved` (or polls `state` / `rounds[roundId]`) and calls `settle(maxBets)`.
4. `settle(maxBets)` (permissionless) → processes up to `maxBets` bets from a stored cursor `nextBetToSettle`, credits winners, adds to the round's running `net` in storage.
5. When the cursor passes `lastBetId`: net transfer with the vault (§5.3, §5.7), round completed, `currentRoundId++`, state OPEN, LP lock lifts.

**What changes compared with this spec:**

- New state `SETTLING`. Bets and spins blocked, LP actions locked (front-running is still possible, since the number is public).
- Storage cursor and running `net` per round: two extra writes per `settle` call, not per bet.
- `MAX_BETS_PER_ROUND` goes away. Each `settle` call only has to fit in the block gas limit, and the keeper picks `maxBets`.
- `settle` is permissionless, so a stuck keeper can't freeze the game: any player who wants their winnings can call it.
- Players still credited automatically; no claims.

**Costs and risks:**

- At least one extra transaction per round, paid by whoever runs the keeper (the house, or a service like Chainlink Automation / Gelato).
- Credits arrive a few blocks after the number instead of in the same transaction. The frontend needs a "settling" status.
- New liveness dependency: if nobody calls `settle`, the round waits. Mitigation: permissionless `settle`, plus a monitoring alert.
- Refund (§5.8) stays only for VRF never answering; a round in `SETTLING` always has a number and can always be settled.

**When to do it:** when rounds regularly fill `MAX_BETS_PER_ROUND`, or when moving to a chain where the callback gas limit is lower.
