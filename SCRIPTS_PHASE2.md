# Scripts Actualizados - Fase 2

## Resumen de Cambios

Los scripts han sido actualizados para soportar la arquitectura de Fase 2 con RouletteVault (ERC4626) y sistema de créditos.

---

## 📁 HelperConfig.s.sol

### Cambios Principales:

1. **Agregada dirección de USDC a NetworkConfig:**
   ```solidity
   struct NetworkConfig {
       address vrfCoordinator;
       bytes32 gasLane;
       uint64 subscriptionId;
       uint32 callbackGasLimit;
       address link;
       address usdc;  // ⭐ NUEVO
   }
   ```

2. **USDC para Sepolia:**
   ```solidity
   address constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
   ```

3. **MockUSDC para Local/Anvil:**
   - Se despliega automáticamente en `getOrCreateAnvilConfig()`
   - Supply inicial: 1,000,000 USDC (6 decimals)

---

## 📁 DeployRoulette.s.sol

### Cambios Principales:

1. **Usa USDC de HelperConfig:**
   - Ya no despliega MockUSDC directamente
   - Obtiene dirección de USDC del config (real o mock según red)

2. **Retorna dirección de USDC en lugar de instancia:**
   ```solidity
   function run() external returns (Roulette, RouletteVault, address, HelperConfig)
   ```

3. **Flujo de Deployment:**
   ```
   1. Obtener USDC address (desde config)
   2. Deploy RouletteVault (ERC4626)
   3. Deploy Roulette (con VRF)
   4. Configurar Vault: setRoulette()
   ```

4. **Output mejorado:**
   - Muestra si es MockUSDC o USDC real
   - Instrucciones claras para Fase 2
   - Addresses para guardar en .env

---

## 📁 Interactions.s.sol

### Scripts VRF (Actualizados):

Ajustados para extraer 6 parámetros del config en lugar de 5:

```solidity
(address vrfCoordinator,, uint64 subId,,, address usdc) = config.activeNetworkConfig();
```

- ✅ `CreateSubscription`
- ✅ `FundSubscription`
- ✅ `AddConsumer`

---

### 🆕 Scripts de Vault - Fase 2

#### 1. **DepositToVaultAsLP**
Deposita USDC como Liquidity Provider y recibe shares (yield-bearing).

```bash
forge script script/Interactions.s.sol:DepositToVaultAsLP \
  --rpc-url $RPC_URL \
  --broadcast
```

**Qué hace:**
- Aprueba USDC al vault
- Deposita 10,000 USDC (configurable)
- Recibe vault shares (ERC4626)
- Muestra LP capital total

#### 2. **DepositCreditsAsPlayer**
Deposita USDC para obtener créditos de juego (1:1).

```bash
forge script script/Interactions.s.sol:DepositCreditsAsPlayer \
  --rpc-url $RPC_URL \
  --broadcast
```

**Qué hace:**
- Aprueba USDC al vault
- Deposita 100 USDC (configurable)
- Recibe credits en Roulette (1:1)
- Los credits se usan para apostar

#### 3. **WithdrawCreditsAsPlayer**
Retira créditos y recibe USDC de vuelta.

```bash
forge script script/Interactions.s.sol:WithdrawCreditsAsPlayer \
  --rpc-url $RPC_URL \
  --broadcast
```

**Qué hace:**
- Verifica balance de credits actual
- Retira 50 USDC worth de credits (configurable)
- Recibe USDC back desde el vault
- Muestra balance final

#### 4. **WithdrawFromVaultAsLP**
Retira USDC como LP (quema shares).

```bash
forge script script/Interactions.s.sol:WithdrawFromVaultAsLP \
  --rpc-url $RPC_URL \
  --broadcast
```

**Qué hace:**
- Verifica shares actuales
- Retira 5,000 USDC (configurable)
- Quema shares proporcionales
- Muestra nuevo LP capital

#### 5. **GetVaultInfo**
Muestra información completa del vault (solo lectura).

```bash
forge script script/Interactions.s.sol:GetVaultInfo \
  --rpc-url $RPC_URL
```

**Muestra:**
- ✅ Direcciones (vault, USDC, roulette)
- ✅ LP Info (capital, shares, capacity, liquidity)
- ✅ Estadísticas (bets, payouts, profit, losses)
- ✅ Risk Management (max bets por multiplier)

**Output ejemplo:**
```
===========================================
RouletteVault Information
===========================================
Vault Address: 0x...
Asset (USDC): 0x...
Roulette: 0x...

--- LP Information ---
LP Capital: 100000 USDC
Total Supply (Shares): 100000
Max Capacity: 10000000 USDC
Available Liquidity: 100000 USDC

--- Statistics ---
Total Bets Placed: 42
Total Bets Amount: 5000 USDC
Total Payouts: 1500 USDC
Total Losses: 3500 USDC
Total Profit: 3500 USDC

--- Risk Management ---
Max Bet (35x multiplier): 2777 USDC
Max Bet (2x multiplier): 33333 USDC
===========================================
```

---

## 📝 Variables de Entorno Requeridas

Agrega al `.env`:

```bash
# Deployment
PRIVATE_KEY=tu_private_key
RPC_URL=tu_rpc_url

# Phase 2 Addresses (después del deployment)
USDC_ADDRESS=0x...
VAULT_ADDRESS=0x...
ROULETTE_ADDRESS=0x...
VRF_COORDINATOR=0x...
```

---

## 🚀 Flujo de Deployment Completo

### 1. Deploy Contracts
```bash
forge script script/DeployRoulette.s.sol --rpc-url $RPC_URL --broadcast
```

### 2. Setup VRF (si subscriptionId = 0)
```bash
# Crear subscription
forge script script/Interactions.s.sol:CreateSubscription --rpc-url $RPC_URL --broadcast

# Fondear subscription
forge script script/Interactions.s.sol:FundSubscription --rpc-url $RPC_URL --broadcast

# Agregar Roulette como consumer
forge script script/Interactions.s.sol:AddConsumer --rpc-url $RPC_URL --broadcast
```

### 3. Depositar Liquidez (LP)
```bash
forge script script/Interactions.s.sol:DepositToVaultAsLP --rpc-url $RPC_URL --broadcast
```

### 4. Depositar Créditos (Player)
```bash
forge script script/Interactions.s.sol:DepositCreditsAsPlayer --rpc-url $RPC_URL --broadcast
```

### 5. Verificar Estado
```bash
forge script script/Interactions.s.sol:GetVaultInfo --rpc-url $RPC_URL
```

---

## 🔄 Diferencias con Fase 1

| Aspecto | Fase 1 | Fase 2 |
|---------|--------|--------|
| Token Management | Roulette tenía USDC | Vault tiene todo el USDC |
| Player Deposits | Direct USDC to Roulette | USDC to Vault → Credits |
| LP System | ❌ No existía | ✅ ERC4626 Vault Shares |
| Yield | ❌ No yield | ✅ LPs earn from losses |
| Scripts | Solo VRF setup | VRF + Vault interactions |

---

## ⚠️ Notas Importantes

1. **USDC Decimals:** 6 decimals (no 18)
2. **Credits:** 1:1 con USDC, stored en Roulette
3. **LP Capital:** Separado de player credits
4. **Capacity:** Solo aplica a LP deposits, no a credits
5. **Yield:** Solo LPs ganan yield, players tienen credits 1:1

---

## 🧪 Testing de Scripts

Para probar localmente con Anvil:

```bash
# Terminal 1: Iniciar Anvil
anvil

# Terminal 2: Deploy
forge script script/DeployRoulette.s.sol --rpc-url http://localhost:8545 --broadcast

# Guardar addresses y ejecutar scripts de interacción
forge script script/Interactions.s.sol:DepositToVaultAsLP --rpc-url http://localhost:8545 --broadcast
```

---

## 📚 Documentación Adicional

- Ver `README.md` para arquitectura completa de Fase 2
- Ver `CHANGELOG_PHASE2.md` para historial de cambios
- Ver `PHASE2_SUMMARY.md` para resumen ejecutivo
