# flaunch-lazy-lp

## Description
**flaunch-lazy-lp** is a protocol designed to manage NFT-based revenue streams by pooling generated ETH into a Uniswap v4 liquidity pool. The system uses a modified version of the `PositionManager.sol` contract, which owns all NFTs minted by creators, capturing their revenue and directing it into the pool. Inspired by Synthetix, the protocol tracks fees generated from the pool and allocates them proportionally to each creator.

## Relevant Contracts

### 1. **FlaunchLPManager.sol**
   - Manages the overall liquidity pool and fee distribution.
   - Handles the aggregation of ETH revenue from NFTs and deposits it into the Uniswap v4 pool.
   - Tracks fee shares for each creator.

### 2. **LpPositionManager.sol (HOOK)**
   - Modified version of the `PositionManager.sol` contract.
   - Owns all NFTs minted by creators, ensuring revenue (ETH) flows into the protocol.

### 3. **LpFlaunch.sol**

## Running Tests with Foundry

To run the tests for this project, ensure you have [Foundry](https://getfoundry.sh/) installed. Then execute the following commands:

```bash
# Install dependencies (if any)
forge install

# Run all tests
forge test

# Run tests with verbose output
forge test -vvv

# Run specific test contract (e.g., FlaunchLPManager.t.sol)
forge test --match-contract FlaunchLPManager
