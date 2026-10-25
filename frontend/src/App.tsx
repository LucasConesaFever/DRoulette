import React, { useState, useEffect } from 'react';
import { useAccount, useBlock, useConnect, useDisconnect, usePublicClient, useReadContract, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { BaseError, ContractFunctionRevertedError, formatUnits, parseUnits } from 'viem';
import { CONTRACTS, BetType, BET_TYPE_LABELS, PAYOUT_MULTIPLIERS, INSIDE_BET_SIZES, getNumberColor, maskToNumbers, formatUSDC, parseUSDC } from './config';
import { ERC20_ABI, VAULT_ABI, ROULETTE_ABI, VRF_COORDINATOR_ABI } from './abis';

// Roulette wheel numbers in order (European)
const WHEEL_NUMBERS = [0, 32, 15, 19, 4, 21, 2, 25, 17, 34, 6, 27, 13, 36, 11, 30, 8, 23, 10, 5, 24, 16, 33, 1, 20, 14, 31, 9, 22, 18, 29, 7, 28, 12, 35, 3, 26];

// Matches RouletteTypes.RouletteState: OPEN (0), CALCULATING (1), DEFICIT (2)
const STATE_OPEN = 0;
const STATE_CALCULATING = 1;
const STATE_DEFICIT = 2;

// Readable messages for the contracts' custom errors; anything else shows its name
const ERROR_MESSAGES: Record<string, string> = {
  Roulette__ExposureLimitExceeded: 'Bet too large: the round would exceed what the vault can cover (exposure limit)',
  Roulette__InsufficientCredits: 'Not enough credits',
  Roulette__InvalidBetAmount: 'Amount outside the bet limits',
  Roulette__InvalidNumbers: 'These numbers are not a valid bet of this type on the table',
  Roulette__InvalidAmount: 'Invalid amount',
  Roulette__RouletteNotOpen: 'Betting is closed (spin pending or deficit open)',
  Roulette__RoundFull: 'This round is full, wait for the next one',
  Roulette__NoActiveBets: 'No bets in this round yet',
  Roulette__SpinDelayNotMet: 'Too soon since the last spin',
  Roulette__AlreadyCalculating: 'A spin is already pending',
  Roulette__VrfTimeoutNotReached: 'The VRF timeout has not passed yet',
  RouletteTypes__NumberOutOfRange: 'Numbers must be between 0 and 36',
  EnforcedPause: 'Betting is paused',
  ERC4626ExceededMaxDeposit: 'Deposit exceeds what the vault accepts (capacity, or LP actions locked)',
  ERC4626ExceededMaxRedeem: 'More shares than you can redeem now (balance, reserve, or LP actions locked)',
  ERC20InsufficientBalance: 'Not enough USDC',
};

function describeError(error: unknown): string {
  if (error instanceof BaseError) {
    const revert = error.walk(e => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError && revert.data?.errorName) {
      const { errorName, args } = revert.data;
      const remaining = errorName.endsWith('NotMet') || errorName.endsWith('NotReached') ? ` (${args?.[0]}s left)` : '';
      return (ERROR_MESSAGES[errorName] ?? errorName) + remaining;
    }
    return error.shortMessage;
  }
  return error instanceof Error ? error.message : String(error);
}

const POCKET = 360 / WHEEL_NUMBERS.length;
const mod360 = (a: number) => ((a % 360) + 360) % 360;
// Point at `radius` and `angle` degrees clockwise from the top, in the wheel's viewBox (centre 0,0)
const polar = (radius: number, angle: number) => {
  const rad = (angle * Math.PI) / 180;
  return [radius * Math.sin(rad), -radius * Math.cos(rad)];
};

function pocketPath(i: number, inner: number, outer: number) {
  const a0 = i * POCKET - POCKET / 2;
  const a1 = a0 + POCKET;
  const [x0, y0] = polar(outer, a0);
  const [x1, y1] = polar(outer, a1);
  const [x2, y2] = polar(inner, a1);
  const [x3, y3] = polar(inner, a0);
  return `M${x0},${y0} A${outer},${outer} 0 0 1 ${x1},${y1} L${x2},${y2} A${inner},${inner} 0 0 0 ${x3},${y3} Z`;
}

// The wheel turns to bring the winning pocket under the pointer at the top; the ball rests there
function RouletteWheel({ winningNumber, isSpinning }: { winningNumber: number | null; isSpinning: boolean }) {
  const [rotation, setRotation] = useState<number | null>(null);

  useEffect(() => {
    if (isSpinning || winningNumber === null) return;
    // Pocket i is drawn at i * POCKET clockwise from the top: a rotation of -i * POCKET puts it on top.
    // The first result is shown in place; later ones land after two more turns.
    const target = -WHEEL_NUMBERS.indexOf(winningNumber) * POCKET;
    setRotation(r => (r === null ? target : r + 720 + mod360(target - r)));
  }, [isSpinning, winningNumber]);

  return (
    <div className="wheel" aria-label={winningNumber !== null ? `Last result ${winningNumber}` : 'Roulette wheel'}>
      <svg viewBox="-100 -100 200 200" role="img">
        <circle r="99" className="wheel-rim" />
        <g className={isSpinning ? 'wheel-spin' : undefined}>
          <g className="wheel-rotor" style={{ transform: `rotate(${rotation ?? 0}deg)` }}>
            <circle r="96" className="wheel-track" />
            {WHEEL_NUMBERS.map((num, i) => (
              <g key={num}>
                <path d={pocketPath(i, 64, 92)} className={`pocket pocket-${getNumberColor(num)}`} />
                <text
                  className="pocket-number"
                  transform={`rotate(${i * POCKET}) translate(0 -80)`}
                  textAnchor="middle"
                  dominantBaseline="central"
                >
                  {num}
                </text>
              </g>
            ))}
            <circle r="64" className="wheel-cone" />
            {Array.from({ length: 8 }, (_, k) => (
              <line key={k} x1="0" y1="-18" x2="0" y2="-60" className="wheel-spoke" transform={`rotate(${k * 45})`} />
            ))}
          </g>
        </g>
        <g className={isSpinning ? 'ball-spin' : undefined}>
          <circle r="96" fill="none" />
          {(isSpinning || winningNumber !== null) && <circle cx="0" cy="-67.5" r="3.6" className="ball" />}
        </g>
        <circle r="20" className="wheel-hub" />
        <path d="M-5,-99 L5,-99 L0,-90 Z" className="wheel-pointer" />
      </svg>
      <div className={`wheel-result ${winningNumber !== null && !isSpinning ? getNumberColor(winningNumber) : ''}`}>
        {isSpinning ? '' : winningNumber ?? ''}
      </div>
    </div>
  );
}

// European layout: 0 on the left, three rows of twelve, "2 to 1" boxes, dozens, then the even-money bets
type TableProps = {
  betType: BetType;
  selectedNumbers: number[];
  selector: number | null;
  disabled: boolean;
  onNumber: (n: number) => void;
  onOutside: (type: BetType, selector?: number) => void;
};

// Whether inside-bet numbers form their shape on the table (rows 1-2-3, 4-5-6, ...); mirrors
// RouletteTypes so the slip can explain a bad pick before it is sent. The contract still decides.
function formsShape(type: BetType, numbers: number[]): boolean {
  const n = [...numbers].sort((a, b) => a - b);
  const [a, b] = n;
  switch (type) {
    case BetType.STRAIGHT_UP:
      return n.length === 1;
    case BetType.SPLIT:
      return n.length === 2 && (a === 0 ? b <= 3 : (b - a === 1 && a % 3 !== 0) || b - a === 3);
    case BetType.STREET:
      return n.length === 3 && a % 3 === 1 && n[1] === a + 1 && n[2] === a + 2;
    case BetType.CORNER:
      if (n.join() === '0,1,2,3') return true;
      return n.length === 4 && a >= 1 && a % 3 !== 0 && n.join() === [a, a + 1, a + 3, a + 4].join();
    case BetType.LINE:
      return n.length === 6 && a % 3 === 1 && n.every((x, i) => x === a + i);
    default:
      return true;
  }
}

// Grid position on the horizontal layout; CSS transposes it for the vertical layout on phones
const place = (row: number, col: number, rowSpan = 1, colSpan = 1) =>
  ({ '--r': row, '--c': col, '--rs': rowSpan, '--cs': colSpan }) as React.CSSProperties;

function BettingTable({ betType, selectedNumbers, selector, disabled, onNumber, onOutside }: TableProps) {
  const inside = betType <= BetType.LINE;
  const isOn = (type: BetType, sel?: number) => betType === type && (sel === undefined || selector === sel);
  const cell = (on: boolean) => `cell${on ? ' cell-on' : ''}`;
  const evenMoney: [BetType, string][] = [
    [BetType.LOW, '1 to 18'],
    [BetType.EVEN, 'Even'],
    [BetType.RED, ''],
    [BetType.BLACK, ''],
    [BetType.ODD, 'Odd'],
    [BetType.HIGH, '19 to 36'],
  ];

  return (
    <div className="table" role="group" aria-label="Betting table">
      <button
        style={place(1, 1, 3, 1)}
        className={`${cell(inside && selectedNumbers.includes(0))} cell-zero`}
        onClick={() => onNumber(0)}
        disabled={disabled}
        aria-pressed={inside && selectedNumbers.includes(0)}
      >
        0
      </button>
      {[3, 2, 1].flatMap(row => Array.from({ length: 12 }, (_, col) => col * 3 + row)).map(num => {
        const on = inside && selectedNumbers.includes(num);
        return (
          <button
            key={num}
            className={`${cell(on)} cell-number cell-${getNumberColor(num)}`}
            style={place(4 - (((num - 1) % 3) + 1), Math.ceil(num / 3) + 1)}
            onClick={() => onNumber(num)}
            disabled={disabled}
            aria-pressed={on}
            aria-label={`${num} ${getNumberColor(num)}`}
          >
            <span>{num}</span>
          </button>
        );
      })}
      {[3, 2, 1].map(col => (
        <button
          key={`col${col}`}
          className={`${cell(isOn(BetType.COLUMN, col))} cell-column`}
          style={place(4 - col, 14)}
          onClick={() => onOutside(BetType.COLUMN, col)}
          disabled={disabled}
          aria-pressed={isOn(BetType.COLUMN, col)}
          aria-label={`Column ${col}, pays 2 to 1`}
        >
          2 to 1
        </button>
      ))}
      {[1, 2, 3].map(d => (
        <button
          key={`dozen${d}`}
          style={place(4, 2 + (d - 1) * 4, 1, 4)}
          className={`${cell(isOn(BetType.DOZEN, d))} cell-dozen`}
          onClick={() => onOutside(BetType.DOZEN, d)}
          disabled={disabled}
          aria-pressed={isOn(BetType.DOZEN, d)}
        >
          {d === 1 ? '1st 12' : d === 2 ? '2nd 12' : '3rd 12'}
        </button>
      ))}
      {evenMoney.map(([type, label], i) => (
        <button
          key={type}
          style={place(5, 2 + i * 2, 1, 2)}
          className={`${cell(isOn(type))} cell-even`}
          onClick={() => onOutside(type)}
          disabled={disabled}
          aria-pressed={isOn(type)}
          aria-label={label || (type === BetType.RED ? 'Red' : 'Black')}
        >
          {label || <span className={`diamond diamond-${type === BetType.RED ? 'red' : 'black'}`} />}
        </button>
      ))}
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
  const { data: receipt, isLoading: isConfirming, isSuccess: isConfirmed } = useWaitForTransactionReceipt({ hash: txHash });
  const isReverted = receipt?.status === 'reverted';
  const publicClient = usePublicClient();
  const [simulationError, setSimulationError] = useState<string | null>(null);

  // Simulate first so a revert shows the contract's error instead of sending a failing transaction
  const send = async (params: Parameters<typeof writeContract>[0]) => {
    setSimulationError(null);
    resetWrite();
    try {
      await publicClient!.simulateContract({ ...params, account: address } as Parameters<NonNullable<typeof publicClient>['simulateContract']>[0]);
    } catch (error) {
      setSimulationError(describeError(error));
      return;
    }
    writeContract(params);
  };

  // Chain time, not the browser clock, decides when a stuck spin can be refunded
  const { data: latestBlock } = useBlock({ watch: true });
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
      // Reset write state after a short delay; a revert stays on screen
      if (isReverted) return;
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
  // Parse a USDC amount from an input, showing the problem instead of sending a wrong amount
  const parseAmount = (value: string): bigint | null => {
    try {
      return parseUSDC(value);
    } catch (error) {
      setSimulationError(describeError(error));
      return null;
    }
  };

  // Approve `spender` (Roulette for credits, Vault for LP deposits) if its allowance is too low
  const approveIfNeeded = async (spender: 'roulette' | 'vault', amount: bigint): Promise<boolean> => {
    const allowance = spender === 'roulette' ? usdcAllowanceRoulette : usdcAllowanceVault;
    if (!allowance || allowance < amount) {
      setIsApproving(true);
      try {
        const hash = await writeContractAsync({
          address: CONTRACTS.USDC,
          abi: ERC20_ABI,
          functionName: 'approve',
          args: [spender === 'roulette' ? CONTRACTS.ROULETTE : CONTRACTS.VAULT, parseUnits('1000000000', 6)],
        });
        // The deposit is simulated next, so the approval must be mined first
        await publicClient!.waitForTransactionReceipt({ hash });
        await (spender === 'roulette' ? refetchAllowanceRoulette() : refetchAllowanceVault());
        setIsApproving(false);
        return true;
      } catch (error) {
        setSimulationError(describeError(error));
        setIsApproving(false);
        return false;
      }
    }
    return true;
  };

  const handleDepositCredits = async () => {
    if (!depositAmount) return;
    const amount = parseAmount(depositAmount);
    if (amount === null) return;
    const approved = await approveIfNeeded('roulette', amount);
    if (!approved) return;
    send({
      address: CONTRACTS.ROULETTE,
      abi: ROULETTE_ABI,
      functionName: 'depositCredits',
      args: [amount],
    });
  };

  const handleWithdrawCredits = () => {
    if (!withdrawAmount) return;
    const amount = parseAmount(withdrawAmount);
    if (amount === null) return;
    send({
      address: CONTRACTS.ROULETTE,
      abi: ROULETTE_ABI,
      functionName: 'withdrawCredits',
      args: [amount],
    });
  };

  const handleLpDeposit = async () => {
    if (!lpDepositAmount) return;
    const amount = parseAmount(lpDepositAmount);
    if (amount === null) return;
    const approved = await approveIfNeeded('vault', amount);
    if (!approved) return;
    send({
      address: CONTRACTS.VAULT,
      abi: VAULT_ABI,
      functionName: 'deposit',
      args: [amount, address!],
    });
  };

  const handleLpWithdraw = () => {
    if (!lpWithdrawShares) return;
    send({
      address: CONTRACTS.VAULT,
      abi: VAULT_ABI,
      functionName: 'redeem',
      args: [parseUnits(lpWithdrawShares, vaultDecimals), address!, address!],
    });
  };

  // Numbers typed or picked on the grid (inside bets), or the dozen/column selector
  const numberTokens = betNumbers.split(',').map(n => n.trim()).filter(n => n !== '');
  const selectedNumbers = numberTokens.filter(n => /^\d+$/.test(n)).map(Number).filter(n => n <= 36);
  // Every token a whole number 0-36, no duplicates
  const numbersValid = selectedNumbers.length === numberTokens.length && new Set(selectedNumbers).size === selectedNumbers.length;
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
  const insideComplete = insideSize !== undefined && numbersValid && selectedNumbers.length === insideSize;
  const shapeOk = !insideComplete || formsShape(betType, selectedNumbers);
  const betNumbersReady = betType > BetType.COLUMN || (numbersValid && selectedNumbers.length === (insideSize ?? 1) && shapeOk);

  const handlePlaceBet = () => {
    if (!betAmount || !betNumbersReady) return;
    const amount = parseAmount(betAmount);
    if (amount === null) return;
    const numbers = betType <= BetType.COLUMN ? selectedNumbers : [];
    send({
      address: CONTRACTS.ROULETTE,
      abi: ROULETTE_ABI,
      functionName: 'placeBet',
      args: [betType, numbers, amount],
    });
  };

  const handleSpin = () => {
    send({
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
    send({
      address: CONTRACTS.VRF_COORDINATOR,
      abi: VRF_COORDINATOR_ABI,
      functionName: 'fulfillRandomWords',
      args: [requestId, CONTRACTS.ROULETTE],
    });
  };

  // Owner only while a VRF request is pending, once vrfTimeout has passed; re-credits every stake
  const handleRefundRound = () => {
    send({
      address: CONTRACTS.ROULETTE,
      abi: ROULETTE_ABI,
      functionName: 'refundRound',
      args: [],
    });
  };

  const handleTogglePause = () => {
    send({
      address: CONTRACTS.ROULETTE,
      abi: ROULETTE_ABI,
      functionName: isPaused ? 'unpause' : 'pause',
      args: [],
    });
  };

  // Permissionless: pulls whatever the vault can pay towards the open deficit
  const handleCoverDeficit = () => {
    send({
      address: CONTRACTS.ROULETTE,
      abi: ROULETTE_ABI,
      functionName: 'coverDeficit',
      args: [],
    });
  };

  const handleFaucet = () => {
    if (!faucetAmount) return;
    const amount = parseAmount(faucetAmount);
    if (amount === null) return;
    send({
      address: CONTRACTS.USDC,
      abi: ERC20_ABI,
      functionName: 'faucet',
      args: [amount],
    });
  };

  const isOwner = address?.toLowerCase() === rouletteOwner?.toLowerCase();
  const isSpinning = gameState === STATE_CALCULATING;
  const isDeficit = gameState === STATE_DEFICIT;
  const [houseWagered, housePaidOut, houseNetPnl] = houseStats ?? [0n, 0n, 0n];
  const refundAvailableAt = spinRequestedAt !== undefined && vrfTimeout !== undefined
    ? Number(spinRequestedAt) + Number(vrfTimeout)
    : undefined;
  const canRefund = isSpinning && refundAvailableAt !== undefined && latestBlock !== undefined
    && Number(latestBlock.timestamp) >= refundAvailableAt;
  const txErrorMessage = simulationError
    ?? (writeError ? describeError(writeError) : isReverted ? 'Transaction reverted' : null);

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

  // Table clicks: a number starts a straight bet unless an inside shape is being built
  const handleTableNumber = (num: number) => {
    if (betType > BetType.LINE) {
      setBetType(BetType.STRAIGHT_UP);
      setBetNumbers(num.toString());
    } else {
      handleNumberClick(num);
    }
  };
  const handleTableOutside = (type: BetType, selector?: number) => {
    setBetType(type);
    setBetNumbers(selector !== undefined ? String(selector) : '');
  };

  const SHAPES: [BetType, string][] = [
    [BetType.STRAIGHT_UP, 'Straight'],
    [BetType.SPLIT, 'Split'],
    [BetType.STREET, 'Street'],
    [BetType.CORNER, 'Corner'],
    [BetType.LINE, 'Line'],
  ];
  const CHIPS = [1, 5, 25, 100, 500];
  const addChip = (value: number) => {
    const current = Number(betAmount) || 0;
    setBetAmount(String(Math.round((current + value) * 1e6) / 1e6));
  };

  // What the bet slip says about the current selection
  const selectionLabel = (() => {
    const name = BET_TYPE_LABELS[betType].replace(/ \(.*\)$/, '');
    if (betType === BetType.DOZEN || betType === BetType.COLUMN) return `${name} ${selectedNumbers[0] ?? ''}`;
    if (betType > BetType.COLUMN) return name;
    return selectedNumbers.length ? `${name} on ${selectedNumbers.join(', ')}` : name;
  })();
  const missingNumbers = insideSize !== undefined ? insideSize - selectedNumbers.length : 0;
  const betAmountValue = Number(betAmount);
  const potentialReturn = betAmountValue > 0 ? betAmountValue * (PAYOUT_MULTIPLIERS[betType] + 1) : null;

  // Plain description of a result: colour, parity, half and dozen
  const describeNumber = (n: number) => {
    if (n === 0) return 'zero, every outside bet loses';
    return [getNumberColor(n), n % 2 ? 'odd' : 'even', n <= 18 ? '1 to 18' : '19 to 36', `${['1st', '2nd', '3rd'][Math.ceil(n / 12) - 1]} 12`].join(', ');
  };

  const roundLine = isDeficit
    ? `Betting is closed until the bank covers a ${formatUSDC(deficit ?? 0n)} USDC shortfall.`
    : isSpinning
      ? `Round ${currentRoundId?.toString() ?? ''} is spinning. Waiting for Chainlink VRF.`
      : isPaused
        ? 'The dealer has paused betting. You can still cash out credits.'
        : `Round ${currentRoundId?.toString() ?? ''} is open for bets.`;
  const myNet = playerStats ? playerStats.totalWon - playerStats.totalLost : 0n;
  const signedUSDC = (v: bigint) => `${v < 0n ? '−' : v > 0n ? '+' : ''}${formatUSDC(v < 0n ? -v : v)}`;

  return (
    <div className="app">
      <header className="masthead">
        <div className="brand">
          <span className="brand-name">DWheel</span>
          <span className="brand-note">European roulette, settled on-chain</span>
        </div>
        <nav className="tabs" aria-label="Sections">
          <button className={activeTab === 'game' ? 'tab tab-on' : 'tab'} onClick={() => setActiveTab('game')} aria-current={activeTab === 'game'}>
            Table
          </button>
          <button className={activeTab === 'vault' ? 'tab tab-on' : 'tab'} onClick={() => setActiveTab('vault')} aria-current={activeTab === 'vault'}>
            Bank
          </button>
        </nav>
        <div className="account">
          {isConnected ? (
            <>
              <dl className="purse">
                <div>
                  <dt>Credits</dt>
                  <dd className="purse-credits">{formatUSDC(credits ?? 0n)}</dd>
                </div>
                <div>
                  <dt>Wallet USDC</dt>
                  <dd>{formatUSDC(usdcBalance ?? 0n)}</dd>
                </div>
              </dl>
              <span className="wallet-address" title={address}>
                {address?.slice(0, 6)}…{address?.slice(-4)}
                {isOwner && <span className="dealer-mark">dealer</span>}
              </span>
              <button className="link-button" onClick={refetchAll}>Refresh</button>
              <button className="link-button" onClick={() => disconnect()}>Disconnect</button>
            </>
          ) : (
            connectors.map(connector => (
              <button key={connector.uid} className="button button-quiet" onClick={() => connect({ connector })}>
                Connect {connector.name}
              </button>
            ))
          )}
        </div>
      </header>

      {isDeficit && (
        <div className="notice notice-alarm" role="alert">
          <p>
            The bank could not pay the last round in full and is short {formatUSDC(deficit ?? 0n)} USDC.
            Betting and bank deposits and withdrawals resume once it is covered. Credits stay withdrawable.
          </p>
          {isConnected && (
            <button className="button button-quiet" onClick={handleCoverDeficit} disabled={isWriting}>
              Cover shortfall
            </button>
          )}
        </div>
      )}

      {activeTab === 'game' && (
        <>
          <main className="floor">
            <section className="wheel-side" aria-label="Wheel">
              <RouletteWheel winningNumber={lastWinningNumber} isSpinning={isSpinning} />
              <p className="round-line">{roundLine}</p>
              {lastWinningNumber !== null && !isSpinning && (
                <p className="last-result">
                  Last result <strong className={`number-badge ${getNumberColor(lastWinningNumber)}`}>{lastWinningNumber}</strong>{' '}
                  {describeNumber(lastWinningNumber)}
                </p>
              )}
              <p className="limits">
                Bets from {formatUSDC(minBet ?? 0n)} to {formatUSDC(maxBet ?? 0n)} USDC
              </p>

              {isOwner && (
                <div className="dealer" aria-label="Dealer controls">
                  <h2>Dealer</h2>
                  <div className="dealer-actions">
                    {gameState === STATE_OPEN && (
                      <button className="button button-brass" onClick={handleSpin} disabled={isWriting}>
                        Spin the wheel
                      </button>
                    )}
                    {isSpinning && (
                      <>
                        <button className="button button-brass" onClick={handleFulfillVRF} disabled={isWriting || !pendingRequestId}>
                          Deliver VRF result (Anvil)
                        </button>
                        <button
                          className="button button-quiet"
                          onClick={handleRefundRound}
                          disabled={isWriting || !canRefund}
                          title={refundAvailableAt ? `Available after ${new Date(refundAvailableAt * 1000).toLocaleTimeString()}` : undefined}
                        >
                          Refund round
                        </button>
                      </>
                    )}
                    <button className="button button-quiet" onClick={handleTogglePause} disabled={isWriting}>
                      {isPaused ? 'Resume betting' : 'Pause betting'}
                    </button>
                  </div>
                  {isSpinning && !!pendingRequestId && (
                    <p className="fine-print">VRF request {pendingRequestId.toString().slice(0, 10)}…</p>
                  )}
                </div>
              )}
            </section>

            <section className="layout-side" aria-label="Place a bet">
              <div className="shapes" role="radiogroup" aria-label="Inside bet">
                {SHAPES.map(([type, label]) => (
                  <button
                    key={type}
                    role="radio"
                    aria-checked={betType === type}
                    className={betType === type ? 'shape shape-on' : 'shape'}
                    onClick={() => handleBetTypeChange(type)}
                  >
                    {label}
                    <span className="shape-pays">{PAYOUT_MULTIPLIERS[type]} to 1</span>
                  </button>
                ))}
              </div>

              <BettingTable
                betType={betType}
                selectedNumbers={selectedNumbers}
                selector={betType === BetType.DOZEN || betType === BetType.COLUMN ? selectedNumbers[0] ?? null : null}
                disabled={!isConnected}
                onNumber={handleTableNumber}
                onOutside={handleTableOutside}
              />

              <div className="slip">
                <div className="slip-selection">
                  <span className="slip-bet">{selectionLabel}</span>
                  <span className="slip-pays">pays {PAYOUT_MULTIPLIERS[betType]} to 1</span>
                  {missingNumbers > 0 && (
                    <span className="slip-hint">
                      Pick {missingNumbers} more {missingNumbers === 1 ? 'number' : 'numbers'} on the table
                    </span>
                  )}
                  {!numbersValid && <span className="slip-hint">Numbers must be whole, 0 to 36, without repeats</span>}
                  {!shapeOk && (
                    <span className="slip-hint">
                      {{
                        [BetType.SPLIT]: 'A split covers two numbers side by side on the table, or 0 with 1, 2 or 3',
                        [BetType.STREET]: 'A street is one row of three, like 4, 5, 6',
                        [BetType.CORNER]: 'A corner is four numbers meeting at a corner, like 1, 2, 4, 5, or 0, 1, 2, 3',
                        [BetType.LINE]: 'A line is two rows next to each other, like 1 to 6',
                      }[betType as number] ?? ''}
                    </span>
                  )}
                </div>
                <div className="slip-stake">
                  <div className="chips" aria-label="Add chips">
                    {CHIPS.map(c => (
                      <button key={c} className="chip" onClick={() => addChip(c)} aria-label={`Add ${c}`}>
                        {c}
                      </button>
                    ))}
                  </div>
                  <label className="stake-field">
                    <span>Stake</span>
                    <input
                      type="text"
                      inputMode="decimal"
                      placeholder="Bet amount"
                      value={betAmount}
                      onChange={e => setBetAmount(e.target.value)}
                    />
                  </label>
                  {betAmount && (
                    <button className="link-button" onClick={() => setBetAmount('')}>
                      Clear
                    </button>
                  )}
                  <button
                    className="button button-brass place-bet"
                    onClick={handlePlaceBet}
                    disabled={isWriting || gameState !== STATE_OPEN || !!isPaused || !betNumbersReady || !isConnected}
                  >
                    Place bet
                  </button>
                </div>
                {potentialReturn !== null && betNumbersReady && (
                  <p className="fine-print">A win returns {potentialReturn.toLocaleString('en-US', { maximumFractionDigits: 6 })} credits, stake included.</p>
                )}
              </div>
            </section>
          </main>

          {isConnected ? (
            <section className="ledger">
              <div className="ledger-bets">
                <h2>Your bets</h2>
                {myCurrentBets.length === 0 && myLastBets.length === 0 && (
                  <p className="empty">No bets yet. Pick a spot on the table, add chips and place your bet.</p>
                )}
                {myCurrentBets.length > 0 && (
                  <>
                    <h3>Round {currentRoundId?.toString()}, {isSpinning ? 'spinning' : 'open'}</h3>
                    <ul className="bet-list">
                      {myCurrentBets.map(bet => (
                        <li key={bet.id.toString()}>
                          <span>{describeBet(bet)}</span>
                          <span className="amount">{formatUSDC(BigInt(bet.amount))}</span>
                        </li>
                      ))}
                    </ul>
                  </>
                )}
                {myLastBets.length > 0 && lastRound && (
                  <>
                    <h3>
                      Round {lastRoundId?.toString()}{' '}
                      {lastRoundSettled ? (
                        <>landed on <span className={`number-badge small ${getNumberColor(lastRound.winningNumber)}`}>{lastRound.winningNumber}</span></>
                      ) : (
                        'was refunded'
                      )}
                    </h3>
                    <ul className="bet-list">
                      {myLastBets.map(bet => {
                        const won = lastRoundSettled && maskToNumbers(bet.numbersMask).includes(lastRound.winningNumber);
                        const payout = BigInt(bet.amount) * BigInt(PAYOUT_MULTIPLIERS[bet.betType] + 1);
                        return (
                          <li key={bet.id.toString()} className={lastRoundSettled ? (won ? 'win' : 'loss') : ''}>
                            <span>{describeBet(bet)}</span>
                            <span className="amount">
                              {formatUSDC(BigInt(bet.amount))}
                              {lastRoundSettled && (won ? ` → won ${formatUSDC(payout)}` : ' → lost')}
                            </span>
                          </li>
                        );
                      })}
                    </ul>
                  </>
                )}
                {playerStats && (
                  <dl className="record">
                    <div>
                      <dt>Bets placed</dt>
                      <dd>{playerStats.totalBets.toString()}</dd>
                    </div>
                    <div>
                      <dt>Wagered</dt>
                      <dd>{formatUSDC(playerStats.totalWagered)}</dd>
                    </div>
                    <div>
                      <dt>Net result</dt>
                      <dd className={myNet >= 0n ? 'win' : 'loss'}>{signedUSDC(myNet)}</dd>
                    </div>
                  </dl>
                )}
              </div>

              <div className="ledger-cashier">
                <h2>Credits</h2>
                <p className="fine-print">One credit is one USDC. Bets are paid in credits; cash out any time.</p>
                <form className="field-row" onSubmit={e => { e.preventDefault(); handleDepositCredits(); }}>
                  <label>
                    <span>Buy credits</span>
                    <input type="text" inputMode="decimal" placeholder="USDC amount" value={depositAmount} onChange={e => setDepositAmount(e.target.value)} />
                  </label>
                  <button className="button button-quiet" type="submit" disabled={isWriting || isApproving}>
                    {isApproving ? 'Approving USDC…' : 'Buy'}
                  </button>
                </form>
                <form className="field-row" onSubmit={e => { e.preventDefault(); handleWithdrawCredits(); }}>
                  <label>
                    <span>Cash out</span>
                    <input type="text" inputMode="decimal" placeholder="Credits" value={withdrawAmount} onChange={e => setWithdrawAmount(e.target.value)} />
                  </label>
                  <button className="button button-quiet" type="submit" disabled={isWriting}>
                    Cash out
                  </button>
                </form>
                <form className="field-row faucet" onSubmit={e => { e.preventDefault(); handleFaucet(); }}>
                  <label>
                    <span>Test USDC</span>
                    <input type="text" inputMode="decimal" placeholder="Amount" value={faucetAmount} onChange={e => setFaucetAmount(e.target.value)} />
                  </label>
                  <button className="button button-quiet" type="submit" disabled={isWriting}>
                    Mint
                  </button>
                </form>
              </div>
            </section>
          ) : (
            <p className="empty connect-hint">Connect a wallet to buy credits and bet.</p>
          )}
        </>
      )}

      {activeTab === 'vault' && (
        <main className="bank">
          <section className="bank-position">
            <h2>Your stake in the bank</h2>
            <p className="fine-print">
              The bank pays winners and keeps what players lose. Your shares rise and fall with its result; the edge is 1 in 37.
            </p>
            {isConnected ? (
              <>
                <dl className="position">
                  <div className="position-value">
                    <dt>Worth now</dt>
                    <dd>{formatUSDC(previewRedeemValue ?? 0n)} USDC</dd>
                  </div>
                  <div>
                    <dt>Shares</dt>
                    <dd>{formatUnits(lpShares ?? 0n, vaultDecimals)}</dd>
                  </div>
                  <div>
                    <dt>Withdrawable now</dt>
                    <dd className="withdrawable">{formatUSDC(lpMaxWithdraw ?? 0n)} USDC</dd>
                  </div>
                </dl>
                {lpLocked && (
                  <p className="notice">Deposits and withdrawals are locked while the wheel is spinning or the bank is short.</p>
                )}
                <form className="field-row" onSubmit={e => { e.preventDefault(); handleLpDeposit(); }}>
                  <label>
                    <span>Add to the bank</span>
                    <input type="text" inputMode="decimal" placeholder="USDC Amount" value={lpDepositAmount} onChange={e => setLpDepositAmount(e.target.value)} />
                  </label>
                  <button className="button button-quiet" type="submit" disabled={isWriting || isApproving || !!lpLocked}>
                    {isApproving ? 'Approving USDC…' : 'Deposit'}
                  </button>
                </form>
                <form className="field-row" onSubmit={e => { e.preventDefault(); handleLpWithdraw(); }}>
                  <label>
                    <span>Withdraw shares</span>
                    <input type="text" inputMode="decimal" placeholder="Shares Amount" value={lpWithdrawShares} onChange={e => setLpWithdrawShares(e.target.value)} />
                  </label>
                  <button className="button button-quiet" type="submit" disabled={isWriting || !!lpLocked}>
                    Withdraw
                  </button>
                </form>
                <button className="link-button max-shares" onClick={() => setLpWithdrawShares(formatUnits(lpMaxRedeem ?? 0n, vaultDecimals))}>
                  Use the most I can withdraw ({formatUnits(lpMaxRedeem ?? 0n, vaultDecimals)} shares)
                </button>
              </>
            ) : (
              <p className="empty">Connect a wallet to deposit into the bank.</p>
            )}
          </section>

          <section className="bank-books">
            <h2>The bank's books</h2>
            <dl className="books">
              <div><dt>Assets</dt><dd>{formatUSDC(vaultTotalAssets ?? 0n)}</dd></div>
              <div><dt>Value of one share</dt><dd>{sharePrice !== undefined ? formatUnits(sharePrice, 6) : '–'}</dd></div>
              <div><dt>Capacity</dt><dd>{formatUSDC(vaultMaxCapacity ?? 0n)}</dd></div>
              <div><dt>Wagered by players</dt><dd>{formatUSDC(houseWagered)}</dd></div>
              <div><dt>Paid to winners</dt><dd>{formatUSDC(housePaidOut)}</dd></div>
              <div><dt>Bank result</dt><dd className={houseNetPnl >= 0n ? 'win' : 'loss'}>{signedUSDC(houseNetPnl)}</dd></div>
            </dl>
            <p className="fine-print">Amounts in USDC. Deposits and withdrawals are {lpLocked ? 'locked right now' : 'open'}.</p>
          </section>
        </main>
      )}

      {(isWriting || isConfirming || isConfirmed || txErrorMessage) && (
        <div className="tx-status" role="status">
          {isWriting && <span className="pending">Confirm in your wallet…</span>}
          {isConfirming && <span className="confirming">Waiting for the block…</span>}
          {isConfirmed && !isReverted && <span className="confirmed">Done.</span>}
          {txErrorMessage && (
            <span className="error" onClick={() => setSimulationError(null)}>{txErrorMessage}</span>
          )}
        </div>
      )}
    </div>
  );
}

export default App;
