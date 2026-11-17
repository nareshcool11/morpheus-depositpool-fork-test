# Morpheus DepositPool — fork test

Foundry fork test against the deployed Morpheus DepositPool (stETH) on
Ethereum mainnet, pinned at block 26432417.

## Run

```sh
forge test
```

No setup beyond Foundry (1.9.0, solc 0.8.20). The fork RPC is a public
endpoint hardcoded in the test (`https://ethereum-rpc.publicnode.com`), so
no RPC URL or environment variable is needed. `forge-std` is vendored in
`lib/`; nothing else is required.

## What the tests do (3 tests)

- `testRewardComparison` — stakes stETH under two referrer configurations,
  advances 90 days, distributes rewards, and compares claimable MOR for
  both stakers.
- `testClaimsExecute` — executes the claim functions on the fork and checks
  the pending balances drain to zero.
- `testReferrerTierState` — sanity check on fork state.

## Fork note

Chainlink feed `latestRoundData` calls are mocked to replay the exact
pinned-block roundId/answer/startedAt with `updatedAt` moved to the warped
block time, because fork state freezes feed timestamps and the consumer's
staleness check would otherwise reject every price after any warp. All
Morpheus logic runs unmocked. The mocked prices are the exact on-chain
values at the pinned block.
