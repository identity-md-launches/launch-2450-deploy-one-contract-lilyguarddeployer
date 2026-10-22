# LilyGuard tests

Run the offline suite from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x3365a2dcb8365bb906291f9d1d59a1be6887bd95b871c834d887c96cc9581065 forge test
```

The pre-existing deployment, access, swap, claim, and invariant suites are preserved.
Two additional files extend them:

- `LilyGuardFailureEdges.t.sol` checks rejected currency pairs, arbitrary unknown pool IDs,
  zero swaps, duplicate initialization, liquidity exhaustion with existing claims, fee rounding,
  and the exact manager ETH balance at which direct payment changes to a claim. Each new fuzz
  property runs 1,000 cases. Failed operations must leave prices, balances, claims, and pause
  state unchanged.
- `LilyGuardLifecycleInvariant.t.sol` runs 256 sequences of 80 actions over three traders and
  three pools. Two pools share a fee tier and two share tick spacing, so the ledger checks
  isolation by the entire PoolId. Actions include trading, independent LP positions, complete
  withdrawals, collecting LP fees, pausing, unauthorized callers, rejected ETH receipts, and
  permissionless redemption. Ghost ledgers check each pool's accrued, delivered, and outstanding
  fees against actual recipient balances and ERC-6909 claims. ETH and IMD conservation cover
  every funded actor. After each sequence, claims must redeem and every LP must exit while
  swaps are paused. A deterministic scenario also exercises these exits.

Fee oracles use the real local v4 PoolManager's `Swap` event and actual ETH balances. The new
lifecycle campaign uses IMD-specified swaps, including dust and partial fills. The required
executed-ETH percentage for ETH-specified swaps is separately reported as a finding in
`.imd-findings.json`, with a self-contained failing Foundry proof. The inherited tests that
calculate that fee from the requested amount do not establish the executed-amount requirement.
The proof was run from `test/scratch/`; scratch files are not part of the deliverable.

Integration is offline: v4-core's real PoolManager is deployed locally, and a minimal ERC-20
stands in for the existing IMD contract at its specified address. Recipient rejection and
reentrancy are simulated by test-only code at the specified recipient address. No live
Robinhood Chain fork or live IMD behavior was verified. No RPC, environment mutation, new
dependency, or configuration change is required.
