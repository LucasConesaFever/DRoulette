import { useState, useEffect } from 'react';
import { useAccount, useConnect, useDisconnect, useReadContract, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { BaseError, formatUnits, parseUnits } from 'viem';
import { CONTRACTS, BetType, BET_TYPE_LABELS, PAYOUT_MULTIPLIERS, INSIDE_BET_SIZES, getNumberColor, maskToNumbers, formatUSDC, parseUSDC } from './config';
import { ERC20_ABI, VAULT_ABI, ROULETTE_ABI, VRF_COORDINATOR_ABI } from './abis';

// Roulette wheel numbers in order (European)
const WHEEL_NUMBERS = [0, 32, 15, 19, 4, 21, 2, 25, 17, 34, 6, 27, 13, 36, 11, 30, 8, 23, 10, 5, 24, 16, 33, 1, 20, 14, 31, 9, 22, 18, 29, 7, 28, 12, 35, 3, 26];

// State labels
// Matches RouletteTypes.RouletteState: OPEN (0), CALCULATING (1), DEFICIT (2)
const STATE_LABELS = ['Open', 'Spinning', 'Deficit'];
const STATE_OPEN = 0;
const STATE_CALCULATING = 1;
const STATE_DEFICIT = 2;

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
    functionName: 'credits',
    args: address ? [address] : undefined,
    query: { refetchInterval: POLL_INTERVAL },
  });

  const { data: gameState, refetch: refetchGameState } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'state',
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

  // Player credits are held by Roulette, so credit deposits need a Roulette allowance
  const { data: usdcAllowanceRoulette, refetch: refetchAllowanceRoulette } = useReadContract({
    address: CONTRACTS.USDC,
    abi: ERC20_ABI,
    functionName: 'allowance',
    args: address ? [address, CONTRACTS.ROULETTE] : undefined,
  });

  // Vault (ERC4626) views. Shares have more decimals than USDC (decimals offset), so read them.
  const { data: vaultDecimalsData } = useReadContract({
    address: CONTRACTS.VAULT,
    abi: VAULT_ABI,
    functionName: 'decimals',
  });
  const vaultDecimals = vaultDecimalsData ?? 12;

  const { data: vaultTotalAssets, refetch: refetchVaultTotalAssets } = useReadContract({
    address: CONTRACTS.VAULT,
    abi: VAULT_ABI,
    functionName: 'totalAssets',
    query: { refetchInterval: POLL_INTERVAL },
  });

  const { data: sharePrice, refetch: refetchSharePrice } = useReadContract({
    address: CONTRACTS.VAULT,
    abi: VAULT_ABI,
    functionName: 'convertToAssets',
    args: vaultDecimalsData !== undefined ? [10n ** BigInt(vaultDecimalsData)] : undefined,
    query: { refetchInterval: POLL_INTERVAL },
  });

  const { data: vaultMaxCapacity } = useReadContract({
    address: CONTRACTS.VAULT,
    abi: VAULT_ABI,
    functionName: 'maxCapacity',
  });

  const { data: lpLocked, refetch: refetchLpLocked } = useReadContract({
    address: CONTRACTS.VAULT,
    abi: VAULT_ABI,
    functionName: 'isLpLocked',
    query: { refetchInterval: POLL_INTERVAL },
  });

  const { data: lpMaxWithdraw, refetch: refetchLpMaxWithdraw } = useReadContract({
    address: CONTRACTS.VAULT,
    abi: VAULT_ABI,
    functionName: 'maxWithdraw',
    args: address ? [address] : undefined,
    query: { refetchInterval: POLL_INTERVAL },
  });

  const { data: lpMaxRedeem, refetch: refetchLpMaxRedeem } = useReadContract({
    address: CONTRACTS.VAULT,
    abi: VAULT_ABI,
    functionName: 'maxRedeem',
    args: address ? [address] : undefined,
    query: { refetchInterval: POLL_INTERVAL },
  });

  // Roulette house / risk views
  const { data: deficit, refetch: refetchDeficit } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'deficit',
    query: { refetchInterval: POLL_INTERVAL },
  });

  const { data: houseStats, refetch: refetchHouseStats } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'getHouseStats',
    query: { refetchInterval: POLL_INTERVAL },
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

  // VRF request of the spin in progress (only meaningful while CALCULATING)
  const { data: pendingRequestId, refetch: refetchPendingRequestId } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'pendingRequestId',
    query: { refetchInterval: POLL_INTERVAL },
  });

  const { data: isPaused, refetch: refetchPaused } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'paused',
    query: { refetchInterval: POLL_INTERVAL },
  });

  // Refund window: the owner can refund a spin VRF hasn't answered after vrfTimeout
  const { data: spinRequestedAt, refetch: refetchSpinRequestedAt } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'spinRequestedAt',
    query: { refetchInterval: POLL_INTERVAL },
  });

  const { data: vrfTimeout } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'vrfTimeout',
  });

  // Bets of the open round and of the last round, to show the player's own
  const lastRoundId = currentRoundId && currentRoundId > 1n ? currentRoundId - 1n : undefined;
  const { data: currentRoundBetIds, refetch: refetchCurrentRoundBetIds } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'getRoundBets',
    args: currentRoundId ? [currentRoundId] : undefined,
    query: { refetchInterval: POLL_INTERVAL },
  });

  const { data: lastRoundBetIds, refetch: refetchLastRoundBetIds } = useReadContract({
    address: CONTRACTS.ROULETTE,
    abi: ROULETTE_ABI,
    functionName: 'getRoundBets',
    args: lastRoundId ? [lastRoundId] : undefined,
  });

  const betIds = [...(currentRoundBetIds ?? []), ...(lastRoundBetIds ?? [])];
  const { data: betsData, refetch: refetchBets } = useReadContracts({
    contracts: betIds.map(id => ({
      address: CONTRACTS.ROULETTE,
      abi: ROULETTE_ABI,
      functionName: 'getBet' as const,
      args: [id] as const,
    })),
    query: { enabled: betIds.length > 0 },
  });

  const myBets = (ids: readonly bigint[] | undefined, offset: number) =>
    (ids ?? []).flatMap((id, i) => {
      const bet = betsData?.[offset + i]?.result;
      return bet && address && bet.player.toLowerCase() === address.toLowerCase() ? [{ id, ...bet }] : [];
    });
  const myCurrentBets = myBets(currentRoundBetIds, 0);
  const myLastBets = myBets(lastRoundBetIds, currentRoundBetIds?.length ?? 0);
  const lastRoundSettled = !!lastRound && lastRound.completed && !lastRound.refunded;

  // Update last winning number when round data changes. A refunded round has no winning number.
  useEffect(() => {
    if (lastRoundSettled) {
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
    refetchAllowanceRoulette();
    refetchVaultTotalAssets();
    refetchSharePrice();
    refetchLpLocked();
    refetchLpMaxWithdraw();
    refetchLpMaxRedeem();
    refetchDeficit();
    refetchHouseStats();
    refetchPlayerStats();
    refetchPreviewRedeem();
    refetchLastRound();
    refetchPendingRequestId();
    refetchPaused();
    refetchSpinRequestedAt();
    refetchCurrentRoundBetIds();
    refetchLastRoundBetIds();
    refetchBets();
  };

  // Actions
  // Approve `spender` (Roulette for credits, Vault for LP deposits) if its allowance is too low
  const approveIfNeeded = async (spender: 'roulette' | 'vault', amount: bigint): Promise<boolean> => {
    const allowance = spender === 'roulette' ? usdcAllowanceRoulette : usdcAllowanceVault;
    if (!allowance || allowance < amount) {
      setIsApproving(true);
      try {
        await writeContractAsync({
          address: CONTRACTS.USDC,
          abi: ERC20_ABI,
          functionName: 'approve',
          args: [spender === 'roulette' ? CONTRACTS.ROULETTE : CONTRACTS.VAULT, parseUnits('1000000000', 6)],
        });
        await new Promise(resolve => setTimeout(resolve, 2000));
        await (spender === 'roulette' ? refetchAllowanceRoulette() : refetchAllowanceVault());
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
    const approved = await approveIfNeeded('roulette', amount);
    if (!approved) return;
    writeContract({
      address: CONTRACTS.ROULETTE,
      abi: ROULETTE_ABI,
      functionName: 'depositCredits',
      args: [amount],
    });
  };

  const handleWithdrawCredits = () => {
    if (!withdrawAmount) return;
    writeContract({
      address: CONTRACTS.ROULETTE,
      abi: ROULETTE_ABI,
      functionName: 'withdrawCredits',
      args: [parseUSDC(withdrawAmount)],
    });
  };

  const handleLpDeposit = async () => {
    if (!lpDepositAmount) return;
    const amount = parseUSDC(lpDepositAmount);
    const approved = await approveIfNeeded('vault', amount);
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
      args: [parseUnits(lpWithdrawShares, vaultDecimals), address!, address!],
    });
  };

  // Numbers typed or picked on the grid (inside bets), or the dozen/column selector
  const selectedNumbers = betNumbers
    .split(',')
    .map(n => parseInt(n.trim()))
    .filter(n => !isNaN(n) && n >= 0 && n <= 36);
  const insideSize = INSIDE_BET_SIZES[betType];

  const handleBetTypeChange = (newType: BetType) => {
    setBetType(newType);
    // Dozen and column default to the first selector, everything else starts empty
    setBetNumbers(newType === BetType.DOZEN || newType === BetType.COLUMN ? '1' : '');
  };

  // Grid click: toggles the number for multi-number inside bets, otherwise starts a straight bet
  const handleNumberClick = (num: number) => {
    if (insideSize && insideSize > 1) {
      const next = selectedNumbers.includes(num)
        ? selectedNumbers.filter(n => n !== num)
        : [...selectedNumbers, num].slice(-insideSize);
      setBetNumbers(next.join(','));
    } else {
      setBetType(BetType.STRAIGHT_UP);
      setBetNumbers(num.toString());
    }
  };

  // Count check only: the contract checks the table shape (neighbours, rows, squares)
  const betNumbersReady = betType > BetType.COLUMN || selectedNumbers.length === (insideSize ?? 1);

  const handlePlaceBet = () => {
    if (!betAmount || !betNumbersReady) return;
    const numbers = betType <= BetType.COLUMN ? selectedNumbers : [];
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
    // Use the pending VRF requestId, not the roundId
    const requestId = pendingRequestId;
    if (!requestId) {
      console.error('No pending VRF request');
      return;
    }
    writeContract({
      address: CONTRACTS.VRF_COORDINATOR,
      abi: VRF_COORDINATOR_ABI,
      functionName: 'fulfillRandomWords',
      args: [requestId, CONTRACTS.ROULETTE],
    });
  };

  // Owner only while a VRF request is pending, once vrfTimeout has passed; re-credits every stake
  const handleRefundRound = () => {
    writeContract({
      address: CONTRACTS.ROULETTE,
      abi: ROULETTE_ABI,
      functionName: 'refundRound',
      args: [],
    });
  };

  const handleTogglePause = () => {
    writeContract({
      address: CONTRACTS.ROULETTE,
      abi: ROULETTE_ABI,
      functionName: isPaused ? 'unpause' : 'pause',
      args: [],
    });
  };

  // Permissionless: pulls whatever the vault can pay towards the open deficit
  const handleCoverDeficit = () => {
    writeContract({
      address: CONTRACTS.ROULETTE,
      abi: ROULETTE_ABI,
      functionName: 'coverDeficit',
      args: [],
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
  const isSpinning = gameState === STATE_CALCULATING;
  const isDeficit = gameState === STATE_DEFICIT;
  const [houseWagered, housePaidOut, houseNetPnl] = houseStats ?? [0n, 0n, 0n];
  const refundAvailableAt = spinRequestedAt !== undefined && vrfTimeout !== undefined
    ? Number(spinRequestedAt) + Number(vrfTimeout)
    : undefined;
  const canRefund = isSpinning && refundAvailableAt !== undefined && Date.now() / 1000 >= refundAvailableAt;
  const writeErrorMessage = writeError
    ? (writeError instanceof BaseError ? writeError.shortMessage : writeError.message)
    : undefined;

  const describeBet = (bet: { betType: number; numbersMask: number }) => {
    const type = bet.betType as BetType;
    const label = BET_TYPE_LABELS[type].replace(/ \(.*\)$/, '');
    if (type <= BetType.LINE) return `${label} ${maskToNumbers(bet.numbersMask).join('-')}`;
    if (type === BetType.DOZEN || type === BetType.COLUMN) {
      const first = maskToNumbers(bet.numbersMask)[0];
      return `${label} ${type === BetType.DOZEN ? Math.ceil(first / 12) : ((first - 1) % 3) + 1}`;
    }
    return label;
  };

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

      {/* Deficit banner: the vault could not fully cover the last round's winnings */}
      {isDeficit && (
        <div className="deficit-banner">
          <div className="deficit-text">
            <strong>Betting paused: house deficit of ${formatUSDC(deficit ?? 0n)} USDC.</strong>
            <span>The vault could not fully cover the last round's payouts. Credits stay withdrawable up to Roulette's USDC balance; betting and LP actions resume once the deficit is covered.</span>
          </div>
          {isConnected && (
            <button className="btn-secondary" onClick={handleCoverDeficit} disabled={isWriting}>
              Cover Deficit
            </button>
          )}
        </div>
      )}

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
                {gameState === STATE_OPEN && (
                  <button
                    className="btn-spin"
                    onClick={handleSpin}
                    disabled={isWriting}
                  >
                    SPIN THE WHEEL
                  </button>
                )}
                {gameState === STATE_CALCULATING && (
                  <>
                    <div className="vrf-status">
                      <span className="vrf-waiting">Waiting for VRF...</span>
                      {!!pendingRequestId && (
                        <span className="vrf-request-id">Request ID: {pendingRequestId.toString().slice(0, 8)}...</span>
                      )}
                    </div>
                    <button
                      className="btn-fulfill"
                      onClick={handleFulfillVRF}
                      disabled={isWriting || !pendingRequestId}
                    >
                      Fulfill VRF (Anvil Only)
                    </button>
                    <button
                      className="btn-secondary"
                      onClick={handleRefundRound}
                      disabled={isWriting || !canRefund}
                      title={refundAvailableAt ? `Available after ${new Date(refundAvailableAt * 1000).toLocaleTimeString()}` : undefined}
                    >
                      Refund Round
                    </button>
                  </>
                )}
                <button className="btn-secondary" onClick={handleTogglePause} disabled={isWriting}>
                  {isPaused ? 'Unpause Betting' : 'Pause Betting'}
                </button>
              </div>
            )}

            {isPaused && (
              <p className="info-text">Betting is paused by the owner. Credits can still be withdrawn.</p>
            )}

            {/* Non-owner sees spinning status */}
            {!isOwner && gameState === STATE_CALCULATING && (
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
                      onChange={(e) => handleBetTypeChange(Number(e.target.value))}
                    >
                      {Object.entries(BET_TYPE_LABELS).map(([value, label]) => (
                        <option key={value} value={value}>{label}</option>
                      ))}
                    </select>
                  </div>

                  {insideSize !== undefined && (
                    <div className="form-group">
                      <label>
                        {insideSize === 1 ? 'Number (0-36)' : `Numbers (${selectedNumbers.length}/${insideSize}, pick on the grid or type)`}
                      </label>
                      <input
                        type="text"
                        placeholder={insideSize === 1 ? 'e.g., 7' : { 2: 'e.g., 1,2 or 1,4', 3: 'e.g., 4,5,6', 4: 'e.g., 1,2,4,5', 6: 'e.g., 1,2,3,4,5,6' }[insideSize]}
                        value={betNumbers}
                        onChange={(e) => setBetNumbers(e.target.value)}
                      />
                    </div>
                  )}

                  {(betType === BetType.DOZEN || betType === BetType.COLUMN) && (
                    <div className="form-group">
                      <label>{betType === BetType.DOZEN ? 'Dozen' : 'Column'}</label>
                      <select value={betNumbers} onChange={(e) => setBetNumbers(e.target.value)}>
                        {betType === BetType.DOZEN ? (
                          <>
                            <option value="1">1st (1-12)</option>
                            <option value="2">2nd (13-24)</option>
                            <option value="3">3rd (25-36)</option>
                          </>
                        ) : (
                          <>
                            <option value="1">1st (1, 4, ... 34)</option>
                            <option value="2">2nd (2, 5, ... 35)</option>
                            <option value="3">3rd (3, 6, ... 36)</option>
                          </>
                        )}
                      </select>
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
                    disabled={isWriting || gameState !== STATE_OPEN || !!isPaused || !betNumbersReady}
                  >
                    Place Bet
                  </button>
                </div>

                {/* Number Grid for quick selection */}
                <div className="number-grid">
                  <button
                    className={`number-btn green ${insideSize && selectedNumbers.includes(0) ? 'selected' : ''}`}
                    onClick={() => handleNumberClick(0)}
                  >
                    0
                  </button>
                  {Array.from({ length: 36 }, (_, i) => i + 1).map(num => (
                    <button
                      key={num}
                      className={`number-btn ${getNumberColor(num)} ${insideSize && selectedNumbers.includes(num) ? 'selected' : ''}`}
                      onClick={() => handleNumberClick(num)}
                    >
                      {num}
                    </button>
                  ))}
                </div>

                {/* Quick bet buttons */}
                <div className="quick-bets">
                  <button
                    className={`quick-bet-btn red ${betType === BetType.RED ? 'selected' : ''}`}
                    onClick={() => handleBetTypeChange(BetType.RED)}
                  >
                    RED
                  </button>
                  <button
                    className={`quick-bet-btn black ${betType === BetType.BLACK ? 'selected' : ''}`}
                    onClick={() => handleBetTypeChange(BetType.BLACK)}
                  >
                    BLACK
                  </button>
                  <button
                    className={`quick-bet-btn ${betType === BetType.ODD ? 'selected' : ''}`}
                    onClick={() => handleBetTypeChange(BetType.ODD)}
                  >
                    ODD
                  </button>
                  <button
                    className={`quick-bet-btn ${betType === BetType.EVEN ? 'selected' : ''}`}
                    onClick={() => handleBetTypeChange(BetType.EVEN)}
                  >
                    EVEN
                  </button>
                  <button
                    className={`quick-bet-btn ${betType === BetType.LOW ? 'selected' : ''}`}
                    onClick={() => handleBetTypeChange(BetType.LOW)}
                  >
                    1-18
                  </button>
                  <button
                    className={`quick-bet-btn ${betType === BetType.HIGH ? 'selected' : ''}`}
                    onClick={() => handleBetTypeChange(BetType.HIGH)}
                  >
                    19-36
                  </button>
                </div>
              </section>

              {/* Your bets: open round, and results of the last round */}
              {(myCurrentBets.length > 0 || myLastBets.length > 0) && (
                <section className="card">
                  <h2>Your Bets</h2>
                  {myCurrentBets.length > 0 && (
                    <div className="form-group">
                      <h3>Round #{currentRoundId?.toString()} ({isSpinning ? 'spinning' : 'open'})</h3>
                      <ul className="bet-list">
                        {myCurrentBets.map(bet => (
                          <li key={bet.id.toString()}>
                            <span>{describeBet(bet)}</span>
                            <span>${formatUSDC(BigInt(bet.amount))}</span>
                          </li>
                        ))}
                      </ul>
                    </div>
                  )}
                  {myLastBets.length > 0 && lastRound && (
                    <div className="form-group">
                      <h3>
                        Round #{lastRoundId?.toString()}{' '}
                        {lastRoundSettled ? <>result <span className={`mini-number ${getNumberColor(lastRound.winningNumber)}`}>{lastRound.winningNumber}</span></> : '(refunded)'}
                      </h3>
                      <ul className="bet-list">
                        {myLastBets.map(bet => {
                          const won = lastRoundSettled && maskToNumbers(bet.numbersMask).includes(lastRound.winningNumber);
                          const payout = BigInt(bet.amount) * BigInt(PAYOUT_MULTIPLIERS[bet.betType] + 1);
                          return (
                            <li key={bet.id.toString()} className={lastRoundSettled ? (won ? 'win' : 'loss') : ''}>
                              <span>{describeBet(bet)}</span>
                              <span>
                                ${formatUSDC(BigInt(bet.amount))}
                                {lastRoundSettled && (won ? ` → won $${formatUSDC(payout)}` : ' → lost')}
                              </span>
                            </li>
                          );
                        })}
                      </ul>
                    </div>
                  )}
                </section>
              )}

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
                <span className="position-label">Position Value</span>
                <span className="position-value">${formatUSDC(previewRedeemValue ?? BigInt(0))}</span>
              </div>
              <div className="position-shares">
                <span className="shares-label">Shares Owned</span>
                <span className="shares-value">{formatUnits(lpShares ?? BigInt(0), vaultDecimals)}</span>
              </div>
              <div className="position-shares">
                <span className="shares-label">Withdrawable Now</span>
                <span className="shares-value">${formatUSDC(lpMaxWithdraw ?? BigInt(0))}</span>
              </div>
            </div>
            {lpLocked && (
              <p className="info-text">LP deposits and withdrawals are locked while a spin is pending or a deficit is open.</p>
            )}
          </section>

          {/* Vault Stats */}
          <section className="card">
            <h2>Vault Stats</h2>
            <div className="stats-grid stats-grid-3">
              <div className="stat-item">
                <span className="stat-value">${formatUSDC(vaultTotalAssets ?? BigInt(0))}</span>
                <span className="stat-label">Total Assets</span>
              </div>
              <div className="stat-item">
                <span className="stat-value">${sharePrice !== undefined ? formatUnits(sharePrice, 6) : '-'}</span>
                <span className="stat-label">Share Price</span>
              </div>
              <div className="stat-item">
                <span className="stat-value">${formatUSDC(vaultMaxCapacity ?? BigInt(0))}</span>
                <span className="stat-label">Max Capacity</span>
              </div>
              <div className="stat-item">
                <span className="stat-value">${formatUSDC(houseWagered)}</span>
                <span className="stat-label">Total Wagered</span>
              </div>
              <div className="stat-item">
                <span className="stat-value">${formatUSDC(housePaidOut)}</span>
                <span className="stat-label">Total Paid Out</span>
              </div>
              <div className={`stat-item ${houseNetPnl >= 0n ? 'win' : 'loss'}`}>
                <span className="stat-value">
                  {houseNetPnl >= 0n ? '+' : '-'}${formatUSDC(houseNetPnl >= 0n ? houseNetPnl : -houseNetPnl)}
                </span>
                <span className="stat-label">House PnL</span>
              </div>
            </div>
            <p className="info-text">LP status: {lpLocked ? 'Locked' : 'Open'}</p>
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
                <button className="btn-primary" onClick={handleLpDeposit} disabled={isWriting || isApproving || !!lpLocked}>
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
                <button className="btn-secondary" onClick={handleLpWithdraw} disabled={isWriting || !!lpLocked}>
                  Withdraw
                </button>
              </div>
              <button
                className="max-btn"
                onClick={() => setLpWithdrawShares(formatUnits(lpMaxRedeem ?? BigInt(0), vaultDecimals))}
              >
                Max ({formatUnits(lpMaxRedeem ?? BigInt(0), vaultDecimals)} shares)
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
          {writeError && <span className="error">{writeErrorMessage}</span>}
        </div>
      )}

      <footer>
        <p>DWheel Roulette</p>
      </footer>
    </div>
  );
}

export default App;
