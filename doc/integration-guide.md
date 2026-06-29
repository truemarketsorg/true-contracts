# Trueo Integration Guide

This guide is for **third-party developers** (front-ends, aggregators, market makers,
keepers) who want to integrate with deployed Trueo contracts. It documents only
the contracts and functions that are meant to be called externally, organized by how
much depth an integration needs. It is self-contained: everything you need is here, in
[`network_config.json`](../network_config.json), or in the contract ABIs
(`forge inspect <Contract> abi`).

## At a glance

| Use case | Contract | What you can do |
|---|---|---|
| **1. Core** | `TruthMarketManager` | Discover markets (list + status) |
| **1. Core** | `TruthMarket` (V1) / `TruthMarketV2` (V2) | Read market state; `mint` / `burn` / `redeem` |
| **1. Core** | `YesNoToken` | YES/NO position tokens (standard ERC20, tradeable on Uniswap) |
| **2. Advanced trading** | `OrderManager` | Range / limit orders on V2 (Uniswap V4) pools |
| **3. Resolution participation** | `OracleCouncil` (+ `OracleBonds`) | Challenge a proposed resolution (`openDispute`, bonded) |

## Core concepts you need first

- **Collateral = `paymentToken`.** Each market settles in a single ERC20 (e.g. USDC, or
  an ERC4626 vault share). Read it from the market via `paymentToken()`. All amounts are
  in that token's decimals unless stated otherwise.
- **Complete sets.** `mint` always produces an equal amount of **YES and NO** tokens
  from collateral (a "complete set"). `burn` does the reverse, redeeming a complete set
  back to collateral. Price discovery for a single side happens by **trading YES or NO on
  Uniswap**, not through the market contract.
- **Position codes** (`winningPosition()` return value): `0` = unresolved, `1` = YES,
  `2` = NO, `3` = CANCELED.
- **Market status** (`getCurrentStatus()` return value, enum `MarketStatus`):
  `0` Created · `1` OpenForResolution · `2` ResolutionProposed · `3` DisputeRaised ·
  `4` SetByCouncil · `5` ResetByCouncil · `6` EscalatedDisputeRaised · `7` Finalized.
  Trading (mint/burn) is open while a market is not yet `Finalized`; `redeem` opens once
  it is `Finalized`.
- **V1 vs V2.** Both coexist; there is no forced migration. V1 markets (`TruthMarket`)
  trade on Uniswap **V3**; V2 markets (`TruthMarketV2`) trade on Uniswap **V4** with
  hooks. The `mint` / `burn` / `redeem` surface is identical; only how you find and trade
  the pools differs (see below).

---

## 1. Core integration

### 1. Discover markets — `TruthMarketManager`

```solidity
function numberOfActiveMarkets() external view returns (uint256);
function getActiveMarketAddress(uint256 index) external view returns (address);
function isActiveMarket(address market) external view returns (bool);
```

Enumerate active markets by iterating `0 .. numberOfActiveMarkets() - 1` and calling
`getActiveMarketAddress(i)`. Validate any market address you receive from elsewhere with
`isActiveMarket(market)` before interacting.

The manager also exposes protocol-wide getters useful for integrators:
`paymentToken()`, `oracleBonds()`, `oracleCouncilAddress()`, `escalationAddress()`,
`firstChallengePeriod()`, `secondChallengePeriod()`. (For a dispute bond, read
`disputerBondAmount()` from the **market**, not the manager — see Section 3.)

### 2. Read a market — `ITruthMarket` / `ITruthMarketV2`

```solidity
function getCurrentStatus() external view returns (MarketStatus);
function winningPosition() external view returns (uint256);
function paymentToken() external view returns (address);
function yesToken() external view returns (address);
function noToken() external view returns (address);

// Pool discovery differs by version:
function getPoolAddresses() external view returns (address yesPool, address noPool); // V1 (Uniswap V3)
function getPoolKeys() external view returns (PoolKey memory yesPoolKey, PoolKey memory noPoolKey); // V2 (Uniswap V4)
function getPoolIds()  external view returns (PoolId yesPoolId, PoolId noPoolId);                    // V2 (Uniswap V4)
```

Use `getPoolAddresses()` for V1 and `getPoolKeys()` / `getPoolIds()` for V2 to locate the
YES and NO pools for trading. To tell the versions apart, you can detect which of these
functions the market exposes, or check the mastercopy it was cloned from.

### 3. Mint a complete set — `mint`

```solidity
function mint(uint256 paymentTokenAmount) external;
```

- Pulls `paymentTokenAmount` of collateral from the caller and mints an **equal amount of
  YES and NO** tokens (decimal-adjusted to the YES/NO token decimals).
- **Prerequisite:** approve `paymentToken` to the **market** address first.
- Reverts after the market is `Finalized`, while paused, or if it would exceed the
  per-side `yesNoTokenCap`.

### 4. Burn a complete set — `burn`

```solidity
function burn(uint256 amount) external;
```

- Burns `amount` of **both** YES and NO from the caller (via `burnFrom`) and returns the
  equivalent collateral.
- **Prerequisite:** the caller must hold ≥ `amount` of both tokens and the market must
  have allowance to burn them (`burnFrom`).
- Reverts after `Finalized` or while paused.

### 5. Redeem after resolution — `redeem` / `withdrawFromCanceledMarket`

```solidity
function redeem(uint256 amount) external;                 // winningPosition == YES or NO
function withdrawFromCanceledMarket() external;           // winningPosition == CANCELED
```

- `redeem` is only callable once the market is `Finalized` with a YES/NO outcome. It burns
  `amount` of the **winning** side token and pays out collateral 1:1 (decimal-adjusted).
  Approve the winning token to the market (`burnFrom`).
- If the market resolved to `CANCELED`, holders instead call
  `withdrawFromCanceledMarket()`, which pays **0.5 collateral per YES/NO token** burned —
  equivalent to full collateral for a complete set, but a partial-position holder (e.g.
  someone who bought only YES on Uniswap) recovers 0.5× face value. Approve **both** the
  YES and NO tokens to the market first — it burns both via `burnFrom`.

### 6. Trading YES / NO tokens

`YesNoToken` is a standard `ERC20Burnable`. Once you hold YES/NO, trade them on Uniswap:

- **V1 markets** → Uniswap **V3** pools from `getPoolAddresses()`.
- **V2 markets** → Uniswap **V4** pools from `getPoolKeys()` / `getPoolIds()`, traded
  through the Uniswap V4 `PoolManager` subject to the market's hook. See the official
  Uniswap V4 documentation at <https://docs.uniswap.org/contracts/v4/overview> for the
  swap interface.

---

## 2. Advanced trading: range orders (`OrderManager`)

`OrderManager` is the range/limit-order book for **V2 (Uniswap V4)** markets. The
order-management surface below is permissionless; everything else on the contract is
role-gated admin (operators, resolvers, the hook) and not part of the integration API.

```solidity
struct CreateOrderParams {
    PoolKey poolKey;
    uint128 amountIn;
    int24 tickLower;
    int24 tickUpper;
    bool zeroForOne;
    bool enablePartialFill;
}
struct CancelOrderParams {
    PoolKey poolKey;
    uint32 orderId;
    uint128 amount0Min;
    uint128 amount1Min;
}

function createOrder(CreateOrderParams calldata params) external returns (uint32 orderId);
function cancelOrder(CancelOrderParams calldata params) external;

function pendingOrder(PoolId poolId, uint32 orderId) external view returns (Order memory);
```

**Events to index:** `OrderCreated`, `OrderFilled`, `OrderPartiallyFilled`,
`OrderCancelled`.

**Caveats:**
- There is a per-tick order cap (`TickOrderCapReached`) and a per-token minimum order
  amount; design batching accordingly.
- Orders support partial fills when `enablePartialFill` is set; track remaining size via
  the `OrderPartiallyFilled` event and `pendingOrder`.

See the `OrderManager` contract ABI for the complete error set and events.

---

## 3. Participating in resolution (`OracleCouncil` + `OracleBonds`)

Anyone can **challenge a proposed resolution** by opening a dispute. This is bonded:
opening a dispute escrows a `paymentToken` bond that is returned or slashed based on the
outcome. Council *voting* is restricted to council members and is **not** an integration
surface.

```solidity
// OracleCouncil
function openDispute(address market, string calldata disputeString) external; // whenNotPaused
```

**Preconditions for `openDispute`:**
1. `market` is active (`isActiveMarket`).
2. Market status is `ResolutionProposed` (2) or `DisputeRaised` (3).
3. The market is not closed for disputes.
4. `disputeString` is non-empty.
5. The caller does not already have an open dispute on this market.
6. The market is not individually paused (`ITruthMarket(market).paused()` is false).
7. **Bond:** the caller must have approved `paymentToken` to **`OracleBonds`** for at
   least `disputerBondAmount()` read from the **market** (each market snapshots the bond
   amount at creation, so the manager's current value may differ). `openDispute` pulls
   the bond via `OracleBonds.sendDisputorBondToMarket`.

**Read surface** (for surfacing dispute state in a UI / keeper):

```solidity
function getMarketOpenDisputes(address market) external view returns (uint256);
function getDispute(address market, uint256 index) external view returns (Dispute memory);
function getDisputeString(address market, uint256 index) external view returns (string memory);
function getDisputeAddressOfDisputor(address market, uint256 index) external view returns (address);
function getDisputeTimestamp(address market, uint256 index) external view returns (uint256);
function isDisputeOpen(address market, uint256 index) external view returns (bool);
function isDisputeCancelled(address market, uint256 index) external view returns (bool);
function isMarketClosedForDisputes(address market) external view returns (bool);
// OracleBonds
function getDisputorBondForMarket(address market, address disputor) external view returns (uint256);
```

**Event to index:** `NewDispute(market, disputeString, disputor)`.

**Bond return:** after a dispute closes, the disputor's bond is settled by the protocol
(returned on a successful challenge, slashed otherwise). `claimUnclosedDisputeBonds` on
`OracleCouncil` and the `issueBondsBackTo*` paths on `OracleBonds` cover the edge cases;
see the `OracleCouncil` and `OracleBonds` contract ABIs.

---

## Typical flows

**Mint and take a YES position**
1. `manager.getActiveMarketAddress(i)` → market.
2. `market.paymentToken()` → collateral; `approve(market, amount)`.
3. `market.mint(amount)` → receive equal YES + NO.
4. Sell the NO leg on Uniswap (V3 pool for V1, V4 pool for V2) to be net-long YES.

**Exit before resolution**
- Hold a complete set? `approve` both tokens and call `market.burn(amount)`.
- Hold one side only? Trade it back on Uniswap.

**Claim after resolution**
- YES/NO outcome: `approve` the winning token, call `market.redeem(amount)`.
- CANCELED: call `market.withdrawFromCanceledMarket()`.

**Challenge a resolution**
1. Confirm `getCurrentStatus()` is `ResolutionProposed` (2) or `DisputeRaised` (3), and
   the market is not paused.
2. `approve(oracleBonds, market.disputerBondAmount())` in `paymentToken`.
3. `oracleCouncil.openDispute(market, "reason …")`.

---

## A note on decimals

`mint` / `burn` / `redeem` convert between collateral decimals and YES/NO token decimals
internally. Pass `mint`'s argument in **`paymentToken` decimals**; `burn` / `redeem` take
amounts in **YES/NO token decimals**. Read both decimals on-chain rather than assuming.
