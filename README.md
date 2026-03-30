# Flashswap — Flash Loan Arbitrage Contract

A Solidity smart contract that executes atomic arbitrage between two Uniswap V2-compatible DEXes using Aave V3 flash loans. If the trade is not profitable, the entire transaction reverts and no funds are lost.

---

## How It Works

Arbitrage opportunities arise when the same token pair is priced differently across two DEXes. This contract exploits that difference atomically — borrowing capital, executing two swaps, repaying the loan and keeping the profit, all within a single transaction.

### Step-by-Step Flow

```
1. Owner calls initiateFlashloan()
        │
        ▼
2. Aave V3 lends the requested asset (e.g. USDC) to the contract
        │
        ▼
3. executeOperation() is triggered automatically by Aave
        │
        ├── Swap 1: tokenIn → tokenOut on routerFrom (buy cheap)
        │
        ├── Swap 2: tokenOut → tokenIn on routerTo (sell expensive)
        │
        └── Profit check: if profit < minProfit → revert
        │
        ▼
4. Aave pulls back the borrowed amount + premium via transferFrom
        │
        ▼
5. Remaining balance = profit, stays in the contract
```

If any step fails or profit is insufficient, the entire transaction reverts. No funds are lost and no loan remains outstanding.

---

## Key Components

### Aave V3 Flash Loan

A flash loan allows borrowing any amount of tokens without collateral, as long as the full amount plus a premium is repaid within the same transaction. This contract implements the `IFlashLoanSimpleReceiver` interface which Aave requires:

- `initiateFlashloan()` — calls `IPool.flashLoanSimple()` to request the loan
- `executeOperation()` — Aave calls this automatically once funds are delivered, passing back the borrowed amount, the premium owed and any custom parameters

### Uniswap V2 Router

The contract interacts with any two Uniswap V2-compatible routers (e.g. Uniswap, Sushiswap, or any fork). It uses `swapExactTokensForTokens()` for both swaps:

- **Swap 1** — buys `tokenOut` with the borrowed `tokenIn` on `routerFrom`, where `tokenOut` is cheaper
- **Swap 2** — sells `tokenOut` back to `tokenIn` on `routerTo`, where `tokenOut` is more expensive

The difference between what comes back and what was borrowed (plus the Aave premium) is the profit.

### ArbitrageParams Struct

To avoid a stack-too-deep error, all swap parameters are ABI-encoded into a `bytes` payload and passed through Aave's `params` field:

```solidity
struct ArbitrageParams {
    address routerFrom;  // DEX to buy tokenOut on
    address routerTo;    // DEX to sell tokenOut on
    address tokenIn;     // asset borrowed from Aave
    address tokenOut;    // intermediate token
    uint256 minProfit;   // minimum acceptable profit, or revert
}
```

### Profit Enforcement

Profit is enforced at two levels:

1. **Swap level** — `amountOutMin` on Swap 2 is set to `repayAmount + minProfit`, so the router itself reverts if the output is insufficient
2. **Balance check** — after both swaps, the contract explicitly verifies that `balanceAfter - repayAmount - balanceBefore >= minProfit`

This double enforcement ensures the transaction always reverts cleanly if the arbitrage is not profitable enough.

---

## Security Considerations

- **`onlyOwner`** — only the contract owner can initiate flash loans, preventing unauthorized use
- **`msg.sender` check in `executeOperation()`** — verifies the caller is the Aave pool, preventing anyone from calling `executeOperation()` directly
- **`initiator` check** — verifies the flash loan was initiated by this contract itself, not by a third party pointing at this contract as the receiver
- **`rescueTokens()`** — allows the owner to recover any tokens accidentally sent to the contract
- **`type(uint256).max` approval to Aave** — acceptable here because the contract is not designed to hold persistent funds; the approval only allows Aave to pull back what it is owed

---

## Technologies Used

| Technology | Purpose |
|---|---|
| Aave V3 | Flash loan provider |
| Uniswap V2 Router | DEX swap execution |
| OpenZeppelin `SafeERC20` | Safe token transfers |
| OpenZeppelin `Ownable` | Access control |
| OpenZeppelin `IERC20` | Token interface |

---

## Usage

```solidity
flashswap.initiateFlashloan(
    asset,      // token to borrow (e.g. USDC)
    amount,     // amount to borrow
    routerFrom, // DEX where tokenOut is cheaper
    routerTo,   // DEX where tokenOut is more expensive
    tokenOut,   // intermediate token (e.g. WETH)
    minProfit   // minimum profit in asset terms, or revert
);
```

> **Note:** This contract is designed for use on networks where Aave V3 and at least two Uniswap V2-compatible DEXes are deployed with meaningful liquidity differences between them.
