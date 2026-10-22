# Local security review

This review covers `src/LilyGuard.sol` and `src/LilyGuardDeployer.sol` and their pinned v4-core
dependencies. It is a local code review and test record, not an independent audit or fork test.

## Boundaries and privileges

- The only owner functions are `pause(PoolId)` and `unpause(PoolId)`. The owner, manager, and
  fee recipient are immutable constructor inputs; neither factory identity nor `tx.origin`
  grants privileges. There are no signatures, arbitrary execution, upgrades, fee changes,
  token approvals, ownership transfers, or discretionary withdrawals.
- `beforeInitialize`, `beforeSwap`, `afterSwap`, and `unlockCallback` check the immutable
  manager. Disabled callbacks always revert and have no address permission bit.
- Every initialized pool must have currency0 = native ETH, currency1 = the specified existing
  IMD, and this hook in its key. There is no creator/router allowlist because none is needed
  for the requested behavior; `sender` and `hookData` confer no authority.
- Constructor account-access recording verifies two creations and no CALL, STATICCALL,
  DELEGATECALL, or CALLCODE. Runtime scanning checks EIP-170 size and no reachable
  DELEGATECALL, CALLCODE, or SELFDESTRUCT in either application contract.

## Delta conservation

Let `f` be the nonnegative fee. Currency1's hook delta is always zero.

| Path | Immediate manager effect on hook's ETH delta | Returned/accounted hook delta | Net |
| --- | --- | --- | --- |
| Direct fee payment | `take(recipient, f)` debits `f` | `+f` | `0` |
| Deferred fee | `mint(hook, ETH id 0, f)` debits `f` and creates the claim | `+f` | `0` |
| Claim redemption | `burn(hook, ETH id 0, f)` credits `f`; `take(recipient, f)` debits `f` | No swap delta | `0` |

For specified ETH, `beforeSwap` returns `(f, 0)` and `afterSwap` returns zero. For unspecified
ETH, `beforeSwap` returns zero and `afterSwap` returns `f`. PoolManager assigns the trader the
raw AMM delta minus this hook delta. Therefore the trader funds the hook fee in ETH, whether
paid immediately or retained as a manager claim. The hook never charges twice or makes an
IMD-denominated claim. Failed router settlement rolls the entire swap and its payment back.

The fee base and net/gross exact-amount convention are explicit in the README. A specified
ETH swap must have raw AMM ETH delta `amountSpecified + f`; otherwise it reverts before any
payment or mint. Token-specified swaps calculate their fee using actual core ETH deltas.
All percentage math uses `FullMath.mulDiv`; checked casts reject fees exceeding v4 int128
delta capacity. Absolute-value handling includes `int256.min` without a negation overflow.

## Reentrancy and claims

The callback/claim reentrancy lock is entered before any fee transfer. Reentering through a
recipient into another pool's swap, claim, initialization, or owner pause cannot alter hook
accounting. The manager's own unlock discipline still enforces all final currency deltas.
This contract does not call `swap` itself, so there is no reachable self-call route that can
use v4's hook self-call exemption to bypass its pause or fees.

During redemption, only `claimFees` can open a per-pool redemption context. The authenticated
`unlockCallback` consumes that context and clears pending fees before burning/taking funds.
It is intentionally invoked inside the already-entered claim guard, rather than trying to
enter a second guard. A failing `take` reverts all of those effects and the claim burn.

Direct payment failure is caught at the manager call boundary, so the failed transfer's
accounting is rolled back before minting an alternative claim. A short manager ETH balance
does not trigger a doomed direct payment. The configured recipient receives all paid and
redeemed fees; a claim caller cannot substitute an address, amount, currency, or pool key.

An attacker may donate ERC-6909 claims or force assets into the hook. They do not increase
any pool's `pendingFees` and there is no sweep authority. The tested claim-balance invariant
concerns the hook's normal fee flow, not unsolicited asset donations.

## Pool isolation and liveness

Token records, pauses, pending fees, and redemption contexts are per-PoolId mappings. Fee
tiers and tick spacings produce separate IDs. Fee redemption for one pool never decrements
another pool's accounting, even though native ETH claims share manager currency ID zero.
The hook keeps no pool price, supply cache, global trading window, or limit counter.

There are no liquidity callbacks, so the owner cannot pause LP withdrawals or zero-liquidity
fee collections. A rejecting recipient defers swap fees, but redemption requires that same
recipient to accept ETH. An immutable recipient cannot be replaced. Claims also require the
manager to hold enough liquid ETH at redemption time. Claiming is a separate locked-manager
operation, not a callback that joins an arbitrary router's active unlock.

The constructor's sequential salt search is intentionally unbounded as specified. Each
iteration reuses a fixed buffer. The eventual launch transaction must be simulated with its
actual address and gas ceiling; local address search results are not predictions for launch.

## Evidence and limits

The delivered suite checks real manager swaps and settlement, raw pool events against balance
changes, all four exact input/output cases, zero/dust fees, rejected/partial trades, pause and
claim isolation, failed redemption rollback, rejected recipients, reentrancy, and constructor
behavior. Fuzz tests use the assignment seed. Stateful invariant runs assert currency
conservation, fee payment plus per-pool claims, pause state, and complete manager settlement.

Local tests use a conventional test ERC-20 at the IMD address and a newly deployed manager;
they do not establish live chain/token bytecode behavior. No live fork, Slither/Mythril run,
formal proof, independent external audit, or network transaction is claimed. Before release,
the launch operator must verify its dependency addresses and actual creation transaction,
the creator must choose the intended price/liquidity and valid pool parameters, and a separate
reviewer should assess the full source and launch handoff. Runtime lints about post-call
events or guard cleanup must be read with the active reentrancy guard and the authenticated
redemption context above; tests exercise those callback paths.
