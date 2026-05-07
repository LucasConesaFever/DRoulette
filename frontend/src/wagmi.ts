import { http, createConfig } from 'wagmi';
import { injected } from 'wagmi/connectors';

// Define Anvil local chain
export const anvilChain = {
  id: 31337,
  name: 'Anvil Local',
  nativeCurrency: {
    decimals: 18,
    name: 'Ether',
    symbol: 'ETH',
  },
  rpcUrls: {
    default: { http: ['http://127.0.0.1:8545'] },
  },
} as const;

// Wagmi config
export const config = createConfig({
  chains: [anvilChain],
  connectors: [
    injected(),
  ],
  transports: {
    [anvilChain.id]: http('http://127.0.0.1:8545'),
  },
});

declare module 'wagmi' {
  interface Register {
    config: typeof config;
  }
}
