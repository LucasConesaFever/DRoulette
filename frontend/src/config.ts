// Contract addresses deployed to Anvil
export const CONTRACTS = {
  USDC: '0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9',
  VAULT: '0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9',
  ROULETTE: '0x4ed7c70f96b99c776995fb64377f0d4ab3b0e1c1',
  VRF_COORDINATOR: '0x5FbDB2315678afecb367f032d93F642f64180aa3',
} as const;

// Owner/Admin wallet (Account 0 from Anvil)
export const OWNER_ADDRESS = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';

// Anvil test accounts with private keys
export const TEST_ACCOUNTS = [
  { address: '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266', privateKey: '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80', label: 'Owner/Admin' },
  { address: '0x70997970C51812dc3A010C7d01b50e0d17dc79C8', privateKey: '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d', label: 'Player 1' },
  { address: '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC', privateKey: '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a', label: 'Player 2' },
  { address: '0x90F79bf6EB2c4f870365E785982E1f101E93b906', privateKey: '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6', label: 'Player 3' },
  { address: '0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65', privateKey: '0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a', label: 'Player 4' },
];

// Bet types enum matching the Solidity contract
export enum BetType {
  STRAIGHT_UP = 0,    // Single number (0-36) - 35:1
  SPLIT = 1,          // Two adjacent numbers - 17:1
  STREET = 2,         // Three numbers in a row - 11:1
  CORNER = 3,         // Four numbers in a square - 8:1
  LINE = 4,           // Six numbers (two rows) - 5:1
  DOZEN = 5,          // 12 numbers (1-12, 13-24, 25-36) - 2:1
  COLUMN = 6,         // 12 numbers in a column - 2:1
  RED = 7,            // All red numbers - 1:1
  BLACK = 8,          // All black numbers - 1:1
  EVEN = 9,           // All even numbers (not 0) - 1:1
  ODD = 10,           // All odd numbers - 1:1
  LOW = 11,           // Numbers 1-18 - 1:1
  HIGH = 12,          // Numbers 19-36 - 1:1
}

export const BET_TYPE_LABELS: Record<BetType, string> = {
  [BetType.STRAIGHT_UP]: 'Straight (35:1)',
  [BetType.SPLIT]: 'Split (17:1)',
  [BetType.STREET]: 'Street (11:1)',
  [BetType.CORNER]: 'Corner (8:1)',
  [BetType.LINE]: 'Line (5:1)',
  [BetType.DOZEN]: 'Dozen (2:1)',
  [BetType.COLUMN]: 'Column (2:1)',
  [BetType.RED]: 'Red (1:1)',
  [BetType.BLACK]: 'Black (1:1)',
  [BetType.EVEN]: 'Even (1:1)',
  [BetType.ODD]: 'Odd (1:1)',
  [BetType.LOW]: 'Low 1-18 (1:1)',
  [BetType.HIGH]: 'High 19-36 (1:1)',
};

// Red numbers in European roulette
export const RED_NUMBERS = [1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36];

// Get color for a number
export function getNumberColor(num: number): 'red' | 'black' | 'green' {
  if (num === 0) return 'green';
  return RED_NUMBERS.includes(num) ? 'red' : 'black';
}

// Format USDC amount (6 decimals)
export function formatUSDC(amount: bigint): string {
  const value = Number(amount) / 1e6;
  return value.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

// Parse USDC amount to bigint
export function parseUSDC(amount: string): bigint {
  const value = parseFloat(amount) * 1e6;
  return BigInt(Math.floor(value));
}
