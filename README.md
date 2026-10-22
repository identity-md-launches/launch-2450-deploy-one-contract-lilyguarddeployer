# LilyGuard

LilyGuard is an immutable Uniswap v4 hook for native ETH / existing IMD pools on Robinhood Chain
(chain ID **4663**). It charges a fixed **100 basis point (1.0%) ETH hook fee** and allows its
owner to pause swaps independently for each `PoolId`. It has no token issuance, LP management,
price oracle, trading limits, backend signer, ownership transfer, fee setter, or upgrade mechanism.

## Launch handoff

Deploy **only `LilyGuardDeployer`**, with these three constructor arguments in this order:

| Argument | Launch value |
| --- | --- |
| `IPoolManager poolManager` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| `address owner` | `$owner`, resolving to `0x5Bff2a2FEcD1d6152676813b21346238733bEAB1` |
| `address feeRecipient` | `0x5Bff2a2FEcD1d6152676813b21346238733bEAB1` |

The constructor accepts **no salt argument**. It hashes the hook creation code and those same
arguments, starts its internal CREATE2 search at salt zero, and increments by one until the
address's low 14 bits equal **`0x20cc`**. It creates `LilyGuard` immediately with the arguments
unchanged. `hook()` returns that deployed hook, and `salt()` records the selected salt.
`HookDeployed` also records both. There is no later deployment or initialization function on
the deployer.

Neither constructor calls another contract; the only child creation is the deployer creating
its hook. Both constructors are nonpayable and reject zero dependencies/beneficiaries. They do
not query code, token supply, chain state, or a recipient. The supplied owner is used directly,
regardless of the factory, deployer's caller, or transaction origin. The addresses above are
the assignment's deployment parameters; local tests do not attest their live chain code.

Salt mining uses a fixed scratch buffer, not an ever-growing allocation. Its gas cost depends
on the eventual deployer address, arguments, and exact compiler output. The launch operator
must simulate the **complete constructor transaction at the actual deployment address** and
provide enough gas for the search and child creation. Changing any build input can change the
first salt. There is intentionally no search cap or caller-selected shortcut.

The separate launch manifest step should record the one application above. This repository
does not supply a `launch.json`, broadcast a transaction, or need a wallet key.

## After launch

1. Read `LilyGuardDeployer.hook()` and use **that address** as `PoolKey.hooks`.
2. The creator initializes a pool separately, with `currency0 = address(0)` (native ETH),
   `currency1 = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` (existing IMD), and its chosen valid
   v4 fee, tick spacing, and starting `sqrtPriceX96`. Initialization is permissionless. There
   is no pool or new token created by the launch transaction.
3. The creator supplies liquidity using its v4 liquidity tooling. The opening price must
   account for raw token units: the pool's price is raw IMD units per wei ETH. The hook needs
   no outside price source or post-deployment configuration. The pool's LP/protocol fee is
   separate from this hook's fixed fee; LilyGuard does not override or administer it.
4. Routers/frontends must settle the hook-adjusted swap deltas and apply their normal input,
   output, and slippage checks to the **final** deltas. Hook data is neither required nor trusted.
5. Monitor `FeeDeferred` and `pendingFees(poolId)`. Anyone can pay gas to call
   `claimFees(poolId)` after a swap has finished settling. There is no operator reward or
   bundled keeper service. A paused pool's fees can still be claimed.

## Fees and exact amounts

Every percentage is calculated with Uniswap's internal `FullMath.mulDiv`, rounding down to
whole wei. Dust below one wei produces no fee. All fees are native ETH; no IMD is taken by
the hook and no external swap is performed.

A specified ETH amount is interpreted at the trader/router boundary: exact ETH input is the
total input budget including the hook fee; exact ETH output is the net output requested by
the trader. This is the v4 `beforeSwap` specified-delta convention used here. Let `A` be the
absolute specified ETH amount and `E` the absolute ETH delta actually executed by the AMM:

| Swap mode | Hook fee | ETH paid/received by trader |
| --- | --- | --- |
| Buy: exact ETH input `A` | `floor(A × 100 / 10000)` | Pays `A`; AMM receives `A − fee` |
| Buy: exact IMD output | `floor(E × 100 / 10000)` | Pays `E + fee` |
| Sell: exact IMD input | `floor(E × 100 / 10000)` | Receives `E − fee` |
| Sell: exact ETH output `A` | `floor(A × 100 / 10000)` | Receives `A`; AMM supplies `A + fee` |

For specified ETH, `afterSwap` checks the AMM's signed ETH delta equals the signed original
specified amount **plus the fee**. A partial fill, whether due to a price limit or unavailable
liquidity, reverts the entire swap before any fee payment. For specified IMD, the fee is based
only on the executed ETH delta; partial fills are accepted by the hook, and the router must
enforce any requested minimum output/full token fill.

The hook first tries to send the current swap's ETH fee directly from PoolManager to the fixed
recipient. A router usually pays its input only after the callback, so a fresh, token-only
manager may not yet have ETH available. If the manager lacks ETH, or its direct payment fails,
the hook instead mints an ETH ERC-6909 claim to itself and records its amount under that pool's
`pendingFees`. The same swap's returned hook delta accounts for the fee in either case.

`claimFees(poolId)` unlocks PoolManager, clears only that pool's pending accounting, burns its
claims, and takes exactly that much ETH to the same recipient. The claim caller receives
nothing. This entry point is intended for a separate call while PoolManager is locked, after
router settlement; it does not join another caller's existing unlock. A failed redemption
reverts atomically and preserves the claims for retry. New direct fee payments do not redeem
older claims automatically.

If the recipient rejects ETH, swaps defer their fees as claims. Redemption remains unavailable
until that recipient can accept ETH and the manager has enough liquid ETH. There is no ability
to redirect fees or replace the recipient. The specified launch recipient is the wallet above.

## Pool-specific storefront API

Solidity `PoolId` encodes as `bytes32` in the ABI. Compute it using v4's `PoolKey.toId()`:
`keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks))`. Fee tier, tick spacing,
and hook address are part of the identity; two ETH/IMD pools do not share pause or fee state.

| Function | Access and behavior |
| --- | --- |
| `pause(PoolId poolId)` | Immutable owner only; pauses this registered pool's swaps |
| `unpause(PoolId poolId)` | Immutable owner only; restores this registered pool's swaps |
| `paused(PoolId poolId)` | Public view; false by default |
| `claimFees(PoolId poolId)` | Anyone; redeems only this pool's pending fees to the recipient; returns amount |
| `pendingFees(PoolId poolId)` | Public view of this pool's deferred ETH fees, in wei |
| `token(PoolId poolId)` | Returns this registered pool's non-ETH currency, IMD |
| `totalSupply(PoolId poolId)` | Calls that token's live `totalSupply()`; no cached or invented supply |

`token`, `totalSupply`, pause/unpause, and fee claiming reject unregistered IDs. Repeating a
pause or unpause is harmless. Claiming a registered pool with no pending fees returns zero.
Liquidity additions, removals, zero-liquidity fee collections, and donations have no hook
restrictions or hook fees, including while swaps are paused.

The Hooks Store block builder can use these exact pool-ID-taking ABI names. Global getters
`owner()`, `feeRecipient()`, and `poolManager()` describe immutable configuration, not pool state.
The owner has only the two pause functions. No caller has an emergency withdrawal or rescue
power over balances or claims sent to the hook outside its normal fee flow.

## Permissions and design

This is a minimal `IHooks` implementation using v4-core interfaces and internal libraries.
Only `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, and
`afterSwapReturnDelta` are enabled. The other callbacks always revert and have no permission
bits. The hook validates its own address flags in its constructor.

[hook-configuration.json](docs/hook-configuration.json) records the conceptual Wizard categories;
the per-pool pause and immutable owner are implemented directly, without inheriting a global
Pausable/Ownable implementation or using a generator. Manager `take`, `mint`, and `burn` calls
are explicit, so a separate CurrencySettler utility is unnecessary.

`beforeInitialize` validates the native-ETH/IMD pair and records its pool ID. `beforeSwap`
checks that pool's pause state and returns a fee delta only when ETH is specified. `afterSwap`
checks full ETH fills or measures actual unspecified ETH, pays/defers the fee, and returns an
unspecified ETH delta only when needed. No callback substitutes for the AMM or handles an
entire input. Enabled callbacks accept calls only from the immutable PoolManager.

All pool records, pause flags, pending fees, and redemption contexts are keyed by `PoolId`.
A contract-wide reentrancy lock protects callback and claim execution; it is an execution
guard, not shared pool accounting. There are no shares, windows, limits, or oracle state.

The design assumes the supplied manager implements the vendored v4 accounting interfaces and
the existing IMD is a v4-compatible ERC-20. It does not make nonstandard IMD transfer behavior
safe or insulate users from the chain, manager, token, or liquidity-provider trust model.

## Build and tests

All Solidity dependencies are vendored as ordinary source files in `lib/`; no git submodule,
package install, RPC, environment configuration, FFI, or filesystem permissions are needed.
`DEPENDENCIES.json` records upstream revisions and archive digests. Upstream licenses are
included beside each dependency. The compiler is pinned to **Solidity 0.8.26**, targeting
Cancun, optimizer 200 runs, with `bytecode_hash = "none"`.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x3365a2dcb8365bb906291f9d1d59a1be6887bd95b871c834d887c96cc9581065 forge test
forge fmt --check
```

Tests use a real local v4 PoolManager and test-only IMD code at the supplied token address.
They exercise all four swap modes, raw core swap logs against actual balances, partial fills,
rounding, invalid pools and callbacks, pause isolation, withdrawals and LP fee collections,
fresh token-only liquidity, failed payments and redemptions, cross-pool claim isolation, and
reentrancy. Constructor tests record account accesses, check the first matching salt, and
check runtime sizes and forbidden escape opcodes. Stateful invariants combine swaps, pauses,
recipient rejection, claims, and LP collections across two pools; the configured run executes
64 sequences of 48 actions. No test reads or mutates environment variables.

See [the local security review](docs/SECURITY.md) for accounting and review limits. Tests are
local implementation checks; live-chain verification, launch simulation at the actual address,
and independent adversarial review remain release responsibilities.
