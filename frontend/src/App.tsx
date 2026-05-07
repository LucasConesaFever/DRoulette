import { useState, useEffect } from 'react';
import { useAccount, useConnect, useDisconnect, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { formatUnits, parseUnits } from 'viem';
import { CONTRACTS, BetType, BET_TYPE_LABELS, getNumberColor, formatUSDC, parseUSDC } from './config';
import { ERC20_ABI, VAULT_ABI, ROULETTE_ABI, VRF_COORDINATOR_ABI } from './abis';

// Roulette wheel numbers in order (European)
const WHEEL_NUMBERS = [0, 32, 15, 19, 4, 21, 2, 25, 17, 34, 6, 27, 13, 36, 11, 30, 8, 23, 10, 5, 24, 16, 33, 1, 20, 14, 31, 9, 22, 18, 29, 7, 28, 12, 35, 3, 26];

// State labels
const STATE_LABELS = ['Open', 'Spinning', 'Settling'];

// Roulette Wheel Component
function RouletteWheel({ winningNumber, isSpinning }: { winningNumber: number | null; isSpinning: boolean }) {
  const [rotation, setRotation] = useState(0);
  const [ballRotation, setBallRotation] = useState(0);

  useEffect(() => {
    if (isSpinning) {
      // Animate wheel spinning
      const interval = setInterval(() => {
        setRotation(r => r + 15);
        setBallRotation(b => b - 25);
      }, 50);
      return () => clearInterval(interval);
    } else if (winningNumber !== null) {
      // Calculate final position based on winning number
      const numberIndex = WHEEL_NUMBERS.indexOf(winningNumber);
      const anglePerSlot = 360 / WHEEL_NUMBERS.length;
      const targetRotation = numberIndex * anglePerSlot + 90; // +90 to align with top
      setRotation(targetRotation);
      setBallRotation(-targetRotation - 180);
    }
  }, [isSpinning, winningNumber]);

  return (
    <div className="wheel-container">
      <div className="wheel-outer">
        <div className="wheel" style={{ transform: `rotate(${rotation}deg)` }}>
          {WHEEL_NUMBERS.map((num, i) => {
            const angle = (i * 360) / WHEEL_NUMBERS.length;
            const color = getNumberColor(num);
            return (
              <div
                key={num}
                className={`wheel-slot ${color}`}
                style={{
                  transform: `rotate(${angle}deg)`,
                }}
              >
                <span className="wheel-number">{num}</span>
              </div>
            );
          })}
        </div>
        <div className="ball-track" style={{ transform: `rotate(${ballRotation}deg)` }}>
          <div className="ball"></div>
        </div>
        <div className="wheel-center">
          {winningNumber !== null && !isSpinning && (
            <div className={`winning-display ${getNumberColor(winningNumber)}`}>
              {winningNumber}
            </div>
          )}
        </div>
      </div>
      <div className="wheel-pointer"></div>
    </div>
  );
}

function App() {
  const { address, isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();

  // Tab state
  const [activeTab, setActiveTab] = useState<'game' | 'vault'>('game');

  // Form states
  const [depositAmount, setDepositAmount] = useState('');
  const [withdrawAmount, setWithdrawAmount] = useState('');
  const [lpDepositAmount, setLpDepositAmount] = useState('');
  const [lpWithdrawShares, setLpWithdrawShares] = useState('');
  const [betType, setBetType] = useState<BetType>(BetType.STRAIGHT_UP);
  const [betNumbers, setBetNumbers] = useState('');
  const [betAmount, setBetAmount] = useState('');
  const [faucetAmount, setFaucetAmount] = useState('1000');

  // Last winning number state
  const [lastWinningNumber, setLastWinningNumber] = useState<number | null>(null);

  // Write contract hooks
  const { writeContract, writeContractAsync, data: txHash, isPending: isWriting, error: writeError, reset: resetWrite } = useWriteContract();
  const { isLoading: isConfirming, isSuccess: isConfirmed } = useWaitForTransactionReceipt({ hash: txHash });
  const [isApproving, setIsApproving] = useState(false);

  // Polling interval for real-time updates (2 seconds)
  const POLL_INTERVAL = 2000;

  // Read balances and states with polling
  const { data: usdcBalance, refetch: refetchUsdcBalance } = useReadContract({
    address: CONTRACTS.USDC,
    abi: ERC20_ABI,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { refetchInterval: POLL_INTERVAL },
  });

  const { data: credits, refetch: refetchCredits } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'getCredits',
    args: address ? [address] : undefined,
    query: { refetchInterval: POLL_INTERVAL },
  });

  const { data: gameState, refetch: refetchGameState } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'getState',
    query: { refetchInterval: POLL_INTERVAL },
  });

  const { data: currentRoundId, refetch: refetchRoundId } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'currentRoundId',
    query: { refetchInterval: POLL_INTERVAL },
  });

  const { data: lpShares, refetch: refetchLpShares } = useReadContract({
    address: CONTRACTS.VAULT,
    abi: VAULT_ABI,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { refetchInterval: POLL_INTERVAL },
  });

  const { data: previewRedeemValue, refetch: refetchPreviewRedeem } = useReadContract({
    address: CONTRACTS.VAULT,
    abi: VAULT_ABI,
    functionName: 'previewRedeem',
    args: lpShares ? [lpShares] : undefined,
    query: { refetchInterval: POLL_INTERVAL },
  });

  const { data: usdcAllowanceVault, refetch: refetchAllowanceVault } = useReadContract({
    address: CONTRACTS.USDC,
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: address ? [address, CONTRACTS.VAULT] : undefined,
  });

  const { data: rouletteOwner } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'owner',
  });

  const { data: minBet } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'minBet',
  });

  const { data: maxBet } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'maxBet',
  });

  const { data: playerStats, refetch: refetchPlayerStats } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'getPlayerStats',
    args: address ? [address] : undefined,
    query: { refetchInterval: POLL_INTERVAL },
  });

  // Get last round info for winning number
  const { data: lastRound, refetch: refetchLastRound } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'getRound',
    args: currentRoundId && currentRoundId > BigInt(1) ? [currentRoundId - BigInt(1)] : undefined,
    query: { refetchInterval: POLL_INTERVAL },
  });

  // Get current round info (for VRF requestId when spinning)
  const { data: currentRound, refetch: refetchCurrentRound } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'getRound',
    args: currentRoundId ? [currentRoundId] : undefined,
    query: { refetchInterval: POLL_INTERVAL },
  });

  // Update last winning number when round data changes
  useEffect(() => {
    if (lastRound && lastRound.completed) {
      setLastWinningNumber(lastRound.winningNumber);
    }
  }, [lastRound]);

  // Auto-refetch all data when transaction is confirmed
  useEffect(() => {
    if (isConfirmed) {
      // Immediate refetch after transaction
      refetchAll();
      // Reset write state after a short delay
      const timeout = setTimeout(() => {
        resetWrite();
      }, 3000);
      return () => clearTimeout(timeout);
    }
  }, [isConfirmed]);

  // Refetch all data
  const refetchAll = () => {
    refetchUsdcBalance();
    refetchCredits();
    refetchGameState();
    refetchRoundId();
    refetchLpShares();
    refetchAllowanceVault();
    refetchPlayerStats();
    refetchPreviewRedeem();
    refetchLastRound();
    refetchCurrentRound();
  };

  // Actions
  const approveIfNeeded = async (amount: bigint): Promise<boolean> => {
    if (!usdcAllowanceVault || usdcAllowanceVault < amount) {
      setIsApproving(true);
      try {
        await writeContractAsync({
          address: CONTRACTS.USDC,
          abi: ERC20_ABI,
          functionName: 'approve',
          args: [CONTRACTS.VAULT, parseUnits('1000000000', 6)],
        });
        await new Promise(resolve => setTimeout(resolve, 2000));
        await refetchAllowanceVault();
        setIsApproving(false);
        return true;
      } catch (error) {
        console.error('Approval failed:', error);
        setIsApproving(false);
        return false;
      }
    }
    return true;
  };

  const handleDepositCredits = async () => {
    if (!depositAmount) return;
    const amount = parseUSDC(depositAmount);
    const approved = await approveIfNeeded(amount);
    if (!approved) return;
    writeContract({
      address: CONTRACTS.VAULT,
      abi: VAULT_ABI,
      functionName: 'depositCredits',
      args: [amount],
    });
  };

  const handleWithdrawCredits = () => {
    if (!withdrawAmount) return;
    writeContract({
      address: CONTRACTS.VAULT,
      abi: VAULT_ABI,
      functionName: 'withdrawCredits',
      args: [parseUSDC(withdrawAmount)],
    });
  };

  const handleLpDeposit = async () => {
    if (!lpDepositAmount) return;
    const amount = parseUSDC(lpDepositAmount);
    const approved = await approveIfNeeded(amount);
    if (!approved) return;
    writeContract({
      address: CONTRACTS.VAULT,
      abi: VAULT_ABI,
      functionName: 'deposit',
      args: [amount, address!],
    });
  };

  const handleLpWithdraw = () => {
    if (!lpWithdrawShares) return;
    writeContract({
      address: CONTRACTS.VAULT,
      abi: VAULT_ABI,
      functionName: 'redeem',
      args: [parseUnits(lpWithdrawShares, 6), address!, address!],
    });
  };

  const handlePlaceBet = () => {
    if (!betAmount) return;
    let numbers: number[] = [];
    if (betType <= BetType.COLUMN) {
      numbers = betNumbers
        .split(',')
        .map(n => parseInt(n.trim()))
        .filter(n => !isNaN(n) && n >= 0 && n <= 36);
    }
    console.log('Placing bet:', { betType, numbers, amount: parseUSDC(betAmount).toString() });
    writeContract({
      address: CONTRACTS.ROULETTE,
      abi: ROULETTE_ABI,
      functionName: 'placeBet',
      args: [betType, numbers, parseUSDC(betAmount)],
    });
  };

  const handleSpin = () => {
    writeContract({
      address: CONTRACTS.ROULETTE,
      abi: ROULETTE_ABI,
      functionName: 'spin',
      args: [],
    });
  };

  const handleFulfillVRF = () => {
    // Use the actual requestId from the current round, not the roundId
    const requestId = currentRound?.requestId;
    if (!requestId) {
      console.error('No requestId found for current round');
      return;
    }
    writeContract({
      address: CONTRACTS.VRF_COORDINATOR,
      abi: VRF_COORDINATOR_ABI,
      functionName: 'fulfillRandomWords',
      args: [requestId, CONTRACTS.ROULETTE],
    });
  };

  const handleFaucet = () => {
    if (!faucetAmount) return;
    writeContract({
      address: CONTRACTS.USDC,
      abi: ERC20_ABI,
      functionName: 'faucet',
      args: [parseUSDC(faucetAmount)],
    });
  };

  const isOwner = address?.toLowerCase() === rouletteOwner?.toLowerCase();
  const isSpinning = gameState === 1;

  return (
    <div className="app">
      <header className="header">
        <h1>DWheel Roulette</h1>
        <div className="wallet-section">
          {isConnected ? (
            <div className="wallet-info">
              <span className="wallet-address">{address?.slice(0, 6)}...{address?.slice(-4)}</span>
              {isOwner && <span className="owner-badge">Owner</span>}
              <button className="disconnect-btn" onClick={() => disconnect()}>Disconnect</button>
              <button className="disconnect-btn" onClick={refetchAll}>Refresh</button>
            </div>
          ) : (
            <div className="connect-buttons">
              {connectors.map((connector) => (
                <button key={connector.id} className="connect-btn" onClick={() => connect({ connector })}>
                  Connect {connector.name}
                </button>
              ))}
            </div>
          )}
        </div>
      </header>

      {/* Tab Navigation */}
      <div className="tab-nav">
        <button
          className={`tab-btn ${activeTab === 'game' ? 'active' : ''}`}
          onClick={() => setActiveTab('game')}
        >
          Game
        </button>
        <button
          className={`tab-btn ${activeTab === 'vault' ? 'active' : ''}`}
          onClick={() => setActiveTab('vault')}
        >
          Vault
        </button>
      </div>

      {/* Game Tab */}
      {activeTab === 'game' && (
        <div className="game-tab">
          {/* Roulette Wheel */}
          <section className="wheel-section">
            <RouletteWheel winningNumber={lastWinningNumber} isSpinning={isSpinning} />

            {/* Game Status */}
            <div className="game-status-bar">
              <div className="status-item">
                <span className="status-label">Status</span>
                <span className={`status-badge ${STATE_LABELS[Number(gameState ?? 0)].toLowerCase()}`}>
                  {STATE_LABELS[Number(gameState ?? 0)]}
                </span>
              </div>
              <div className="status-item">
                <span className="status-label">Round</span>
                <span className="status-value">#{currentRoundId?.toString() || '0'}</span>
              </div>
              <div className="status-item">
                <span className="status-label">Bet Range</span>
                <span className="status-value">{formatUSDC(minBet ?? BigInt(0))} - {formatUSDC(maxBet ?? BigInt(0))}</span>
              </div>
              {lastWinningNumber !== null && (
                <div className="status-item last-number">
                  <span className="status-label">Last Result</span>
                  <span className={`mini-number ${getNumberColor(lastWinningNumber)}`}>
                    {lastWinningNumber}
                  </span>
                </div>
              )}
            </div>

            {/* Owner Spin Controls - Only visible to owner */}
            {isOwner && (
              <div className="spin-controls">
                {gameState === 0 && (
                  <button
                    className="btn-spin"
                    onClick={handleSpin}
                    disabled={isWriting}
                  >
                    SPIN THE WHEEL
                  </button>
                )}
                {gameState === 1 && (
                  <>
                    <div className="vrf-status">
                      <span className="vrf-waiting">Waiting for VRF...</span>
                      {currentRound?.requestId && (
                        <span className="vrf-request-id">Request ID: {currentRound.requestId.toString().slice(0, 8)}...</span>
                      )}
                    </div>
                    <button
                      className="btn-fulfill"
                      onClick={handleFulfillVRF}
                      disabled={isWriting || !currentRound?.requestId}
                    >
                      Fulfill VRF (Anvil Only)
                    </button>
                  </>
                )}
              </div>
            )}

            {/* Non-owner sees spinning status */}
            {!isOwner && gameState === 1 && (
              <div className="spin-controls">
                <div className="vrf-status">
                  <span className="vrf-waiting">Wheel is spinning... Waiting for result</span>
                </div>
              </div>
            )}
          </section>

          {isConnected && (
            <>
              {/* Balances */}
              <section className="card balances-card">
                <h2>Your Balances</h2>
                <div className="balance-grid">
                  <div className="balance-item">
                    <span className="balance-label">USDC Wallet</span>
                    <span className="balance-value">${formatUSDC(usdcBalance ?? BigInt(0))}</span>
                  </div>
                  <div className="balance-item highlight">
                    <span className="balance-label">Game Credits</span>
                    <span className="balance-value">${formatUSDC(credits ?? BigInt(0))}</span>
                  </div>
                </div>
              </section>

              {/* USDC Faucet */}
              <section className="card">
                <h2>Get USDC</h2>
                <div className="form-row">
                  <input
                    type="number"
                    placeholder="Amount"
                    value={faucetAmount}
                    onChange={(e) => setFaucetAmount(e.target.value)}
                  />
                  <button className="btn-primary" onClick={handleFaucet} disabled={isWriting}>
                    Mint USDC
                  </button>
                </div>
              </section>

              {/* Credits Management */}
              <section className="card">
                <h2>Credits</h2>
                <div className="form-group">
                  <h3>Deposit USDC to Credits</h3>
                  <div className="form-row">
                    <input
                      type="number"
                      placeholder="Amount"
                      value={depositAmount}
                      onChange={(e) => setDepositAmount(e.target.value)}
                    />
                    <button className="btn-primary" onClick={handleDepositCredits} disabled={isWriting || isApproving}>
                      {isApproving ? 'Approving...' : 'Deposit'}
                    </button>
                  </div>
                </div>
                <div className="form-group">
                  <h3>Withdraw Credits to USDC</h3>
                  <div className="form-row">
                    <input
                      type="number"
                      placeholder="Amount"
                      value={withdrawAmount}
                      onChange={(e) => setWithdrawAmount(e.target.value)}
                    />
                    <button className="btn-secondary" onClick={handleWithdrawCredits} disabled={isWriting}>
                      Withdraw
                    </button>
                  </div>
                </div>
              </section>

              {/* Betting */}
              <section className="card betting-card">
                <h2>Place Bet</h2>
                <div className="betting-form">
                  <div className="form-group">
                    <label>Bet Type</label>
                    <select
                      value={betType.toString()}
                      onChange={(e) => {
                        const newType = Number(e.target.value);
                        setBetType(newType);
                        if (newType >= BetType.RED) {
                          setBetNumbers('');
                        }
                      }}
                    >
                      {Object.entries(BET_TYPE_LABELS).map(([value, label]) => (
                        <option key={value} value={value}>{label}</option>
                      ))}
                    </select>
                  </div>

                  {betType === BetType.STRAIGHT_UP && (
                    <div className="form-group">
                      <label>Numbers (0-36)</label>
                      <input
                        type="text"
                        placeholder="e.g., 7 or 1,2,3"
                        value={betNumbers}
                        onChange={(e) => setBetNumbers(e.target.value)}
                      />
                    </div>
                  )}

                  <div className="form-group">
                    <label>Amount (USDC)</label>
                    <input
                      type="number"
                      placeholder="Bet amount"
                      value={betAmount}
                      onChange={(e) => setBetAmount(e.target.value)}
                    />
                  </div>

                  <button
                    className="btn-primary bet-btn"
                    onClick={handlePlaceBet}
                    disabled={isWriting || gameState !== 0}
                  >
                    Place Bet
                  </button>
                </div>

                {/* Number Grid for quick selection */}
                <div className="number-grid">
                  <button
                    className={`number-btn green ${betNumbers === '0' ? 'selected' : ''}`}
                    onClick={() => { setBetType(BetType.STRAIGHT_UP); setBetNumbers('0'); }}
                  >
                    0
                  </button>
                  {Array.from({ length: 36 }, (_, i) => i + 1).map(num => (
                    <button
                      key={num}
                      className={`number-btn ${getNumberColor(num)} ${betNumbers === num.toString() ? 'selected' : ''}`}
                      onClick={() => { setBetType(BetType.STRAIGHT_UP); setBetNumbers(num.toString()); }}
                    >
                      {num}
                    </button>
                  ))}
                </div>

                {/* Quick bet buttons */}
                <div className="quick-bets">
                  <button
                    className={`quick-bet-btn red ${betType === BetType.RED ? 'selected' : ''}`}
                    onClick={() => { setBetType(BetType.RED); setBetNumbers(''); }}
                  >
                    RED
                  </button>
                  <button
                    className={`quick-bet-btn black ${betType === BetType.BLACK ? 'selected' : ''}`}
                    onClick={() => { setBetType(BetType.BLACK); setBetNumbers(''); }}
                  >
                    BLACK
                  </button>
                  <button
                    className={`quick-bet-btn ${betType === BetType.ODD ? 'selected' : ''}`}
                    onClick={() => { setBetType(BetType.ODD); setBetNumbers(''); }}
                  >
                    ODD
                  </button>
                  <button
                    className={`quick-bet-btn ${betType === BetType.EVEN ? 'selected' : ''}`}
                    onClick={() => { setBetType(BetType.EVEN); setBetNumbers(''); }}
                  >
                    EVEN
                  </button>
                  <button
                    className={`quick-bet-btn ${betType === BetType.LOW ? 'selected' : ''}`}
                    onClick={() => { setBetType(BetType.LOW); setBetNumbers(''); }}
                  >
                    1-18
                  </button>
                  <button
                    className={`quick-bet-btn ${betType === BetType.HIGH ? 'selected' : ''}`}
                    onClick={() => { setBetType(BetType.HIGH); setBetNumbers(''); }}
                  >
                    19-36
                  </button>
                </div>
              </section>

              {/* Player Stats */}
              {playerStats && (
                <section className="card">
                  <h2>Your Stats</h2>
                  <div className="stats-grid stats-grid-3">
                    <div className="stat-item">
                      <span className="stat-value">{playerStats.totalBets?.toString()}</span>
                      <span className="stat-label">Total Bets</span>
                    </div>
                    <div className="stat-item">
                      <span className="stat-value">${formatUSDC(playerStats.totalWagered ?? BigInt(0))}</span>
                      <span className="stat-label">Wagered</span>
                    </div>
                    <div className={`stat-item ${(playerStats.totalWon ?? BigInt(0)) >= (playerStats.totalLost ?? BigInt(0)) ? 'win' : 'loss'}`}>
                      <span className="stat-value">
                        {(playerStats.totalWon ?? BigInt(0)) >= (playerStats.totalLost ?? BigInt(0)) ? '+' : '-'}
                        ${formatUSDC(
                          (playerStats.totalWon ?? BigInt(0)) >= (playerStats.totalLost ?? BigInt(0))
                            ? (playerStats.totalWon ?? BigInt(0)) - (playerStats.totalLost ?? BigInt(0))
                            : (playerStats.totalLost ?? BigInt(0)) - (playerStats.totalWon ?? BigInt(0))
                        )}
                      </span>
                      <span className="stat-label">PnL</span>
                    </div>
                  </div>
                </section>
              )}
            </>
          )}
        </div>
      )}

      {/* Vault Tab */}
      {activeTab === 'vault' && isConnected && (
        <div className="vault-tab">
          {/* Your LP Position */}
          <section className="card vault-position-card">
            <h2>Your LP Position</h2>
            <div className="vault-position">
              <div className="position-main">
                <span className="position-label">Withdrawable Value</span>
                <span className="position-value">${formatUSDC(previewRedeemValue ?? BigInt(0))}</span>
              </div>
              <div className="position-shares">
                <span className="shares-label">Shares Owned</span>
                <span className="shares-value">{formatUnits(lpShares ?? BigInt(0), 6)}</span>
              </div>
            </div>
          </section>

          {/* LP Deposit */}
          <section className="card">
            <h2>Provide Liquidity</h2>
            <p className="info-text">Deposit USDC to earn yield from house edge profits. Your position value changes based on player wins/losses.</p>
            <div className="form-group">
              <h3>Deposit USDC</h3>
              <div className="form-row">
                <input
                  type="number"
                  placeholder="USDC Amount"
                  value={lpDepositAmount}
                  onChange={(e) => setLpDepositAmount(e.target.value)}
                />
                <button className="btn-primary" onClick={handleLpDeposit} disabled={isWriting || isApproving}>
                  {isApproving ? 'Approving...' : 'Deposit'}
                </button>
              </div>
            </div>
          </section>

          {/* LP Withdraw */}
          <section className="card">
            <h2>Withdraw Liquidity</h2>
            <p className="info-text">Redeem your LP shares for USDC. Value may be higher or lower than deposited amount based on house performance.</p>
            <div className="form-group">
              <h3>Withdraw Shares</h3>
              <div className="form-row">
                <input
                  type="number"
                  placeholder="Shares Amount"
                  value={lpWithdrawShares}
                  onChange={(e) => setLpWithdrawShares(e.target.value)}
                />
                <button className="btn-secondary" onClick={handleLpWithdraw} disabled={isWriting}>
                  Withdraw
                </button>
              </div>
              <button
                className="max-btn"
                onClick={() => setLpWithdrawShares(formatUnits(lpShares ?? BigInt(0), 6))}
              >
                Max ({formatUnits(lpShares ?? BigInt(0), 6)} shares)
              </button>
            </div>
          </section>
        </div>
      )}

      {/* Transaction Status */}
      {(isWriting || isConfirming || writeError) && (
        <div className="tx-status">
          {isWriting && <span className="pending">Sending transaction...</span>}
          {isConfirming && <span className="confirming">Confirming...</span>}
          {isConfirmed && <span className="confirmed">Transaction confirmed!</span>}
          {writeError && <span className="error">{writeError.message}</span>}
        </div>
      )}

      <footer>
        <p>DWheel Roulette</p>
      </footer>
    </div>
  );
}

export default App;
