// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {LilyGuard} from "../src/LilyGuard.sol";
import {LilyGuardTestBase} from "./LilyGuardTestBase.sol";
import {PoolActor} from "./mocks/PoolActor.sol";
import {RecipientProbe} from "./mocks/RecipientProbe.sol";

/// @dev Extends the original swap/claim campaign with independent LP positions and an exact
/// per-pool ledger. The three keys distinguish fee tier from tick spacing independently.
contract LilyGuardLifecycleHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    LilyGuard public immutable hook;
    RecipientProbe public immutable recipient;
    address private immutable controller;
    PoolActor[3] public actors;
    PoolKey[3] private keys;
    uint256[3] public accrued;
    uint256[3] public delivered;
    uint256[3] public outstanding;
    bool[3] public expectedPaused;
    uint128[3][3] public liquidity;
    bool public rejecting;

    bytes32 private constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    constructor(IPoolManager manager_, LilyGuard hook_, PoolKey[3] memory keys_) {
        manager = manager_;
        hook = hook_;
        recipient = RecipientProbe(payable(hook_.feeRecipient()));
        controller = msg.sender;
        for (uint256 i; i < 3; ++i) {
            keys[i] = keys_[i];
            actors[i] = new PoolActor(manager_);
        }
    }

    function seed() external {
        require(msg.sender == controller, "controller");
        for (uint256 i; i < 3; ++i) {
            actors[0].modify(keys[i], -600, 600, 1_000 ether);
            liquidity[0][i] = 1_000 ether;
        }
    }

    /// @dev IMD specifies the amount in this campaign, so the independent fee oracle is always
    /// the executed ETH amount from core's Swap log, including zero and partial fills.
    function swap(uint8 rawPool, uint8 rawActor, uint96 rawAmount, bool buy) external {
        uint256 p = rawPool % 3;
        PoolActor actor = actors[rawActor % 3];
        uint256 amount = bound(uint256(rawAmount), 1, 0.05 ether);
        SwapParams memory params = SwapParams(
            buy,
            buy ? int256(amount) : -int256(amount),
            buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        if (expectedPaused[p]) {
            (bool ok,) = address(actor).call(abi.encodeCall(PoolActor.swap, (keys[p], params)));
            assertFalse(ok, "paused swap succeeded");
            return;
        }
        (uint160 price,,,) = manager.getSlot0(keys[p].toId());
        if (price == params.sqrtPriceLimitX96) {
            // An empty pool can reach core's extreme price. Repeating a swap in the same
            // direction is then an invalid price limit, rather than a hook liveness failure.
            vm.expectRevert(abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, price, price));
            actor.swap(keys[p], params);
            return;
        }

        uint256 beforePaid = address(recipient).balance;
        uint256 beforeETH = address(actor).balance;
        vm.recordLogs();
        BalanceDelta result = actor.swap(keys[p], params);
        (int128 rawETH, int128 rawIMD) = _coreDelta(vm.getRecordedLogs(), keys[p].toId());
        uint256 fee = (rawETH < 0 ? uint256(-int256(rawETH)) : uint256(int256(rawETH))) / 100;
        uint256 paid = address(recipient).balance - beforePaid;
        assertLe(paid, fee, "fee paid twice");
        assertEq(int256(result.amount0()), int256(rawETH) - int256(fee));
        assertEq(result.amount1(), rawIMD, "hook took IMD");
        assertEq(int256(address(actor).balance) - int256(beforeETH), int256(result.amount0()));
        accrued[p] += fee;
        delivered[p] += paid;
        outstanding[p] += fee - paid;
    }

    function changeLiquidity(uint8 rawPool, uint8 rawActor, uint96 rawAmount, bool remove, bool all)
        external
    {
        uint256 p = rawPool % 3;
        uint256 a = rawActor % 3;
        uint256 owned = liquidity[a][p];
        if (remove && owned == 0) return;
        uint256 amount = remove
            ? (all ? owned : bound(uint256(rawAmount), 1, owned))
            : bound(uint256(rawAmount), 1, 10 ether);
        uint256 recipientBefore = address(recipient).balance;
        BalanceDelta delta = actors[a].modify(keys[p], -600, 600, remove ? -int256(amount) : int256(amount));
        assertEq(address(recipient).balance, recipientBefore, "LP operation charged a hook fee");
        if (remove) {
            assertGe(delta.amount0(), 0, "removal owes ETH");
            assertGe(delta.amount1(), 0, "removal owes IMD");
            liquidity[a][p] -= uint128(amount);
        } else {
            liquidity[a][p] += uint128(amount);
        }
    }

    function collect(uint8 rawPool, uint8 rawActor) external {
        uint256 p = rawPool % 3;
        uint256 a = rawActor % 3;
        if (liquidity[a][p] == 0) return;
        uint256 recipientBefore = address(recipient).balance;
        BalanceDelta delta = actors[a].modify(keys[p], -600, 600, 0);
        assertGe(delta.amount0(), 0);
        assertGe(delta.amount1(), 0);
        assertEq(address(recipient).balance, recipientBefore, "collect charged a hook fee");
    }

    function setPaused(uint8 rawPool, bool pause_) external {
        uint256 p = rawPool % 3;
        vm.prank(hook.owner());
        if (pause_) hook.pause(keys[p].toId());
        else hook.unpause(keys[p].toId());
        expectedPaused[p] = pause_;
    }

    function unauthorizedPause(uint8 rawPool, uint8 rawActor, bool pause_) external {
        PoolId id = keys[rawPool % 3].toId();
        // Even the owner's tx.origin cannot authorize a different msg.sender.
        vm.prank(address(actors[rawActor % 3]), hook.owner());
        (bool ok, bytes memory reason) = address(hook)
            .call(pause_ ? abi.encodeCall(LilyGuard.pause, (id)) : abi.encodeCall(LilyGuard.unpause, (id)));
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(LilyGuard.OnlyOwner.selector));
    }

    function setRecipientRejection(bool reject_) external {
        recipient.setReject(reject_);
        rejecting = reject_;
    }

    function claim(uint8 rawPool, uint8 rawActor) external {
        _claim(rawPool % 3, address(actors[rawActor % 3]));
    }

    /// @dev Called after every random sequence. Every claim and LP position must remain exit-able,
    /// including positions belonging to traders other than the original liquidity provider.
    function exitAll() external {
        require(msg.sender == controller, "controller");
        recipient.setReject(false);
        rejecting = false;
        for (uint256 p; p < 3; ++p) {
            // Exercise exits while paused, then restore the trading state.
            vm.prank(hook.owner());
            hook.pause(keys[p].toId());
            expectedPaused[p] = true;
            _claim(p, address(actors[2]));
            for (uint256 a; a < 3; ++a) {
                uint256 owned = liquidity[a][p];
                if (owned == 0) continue;
                BalanceDelta delta = actors[a].modify(keys[p], -600, 600, -int256(owned));
                assertGe(delta.amount0(), 0);
                assertGe(delta.amount1(), 0);
                liquidity[a][p] = 0;
            }
            vm.prank(hook.owner());
            hook.unpause(keys[p].toId());
            expectedPaused[p] = false;
        }
    }

    function _claim(uint256 p, address caller) private {
        uint256 owed = outstanding[p];
        uint256 beforePaid = address(recipient).balance;
        vm.prank(caller);
        if (rejecting && owed != 0) {
            (bool ok,) = address(hook).call(abi.encodeCall(LilyGuard.claimFees, (keys[p].toId())));
            assertFalse(ok, "rejecting recipient received a claim");
        } else {
            assertEq(hook.claimFees(keys[p].toId()), owed, "wrong pool redeemed");
            delivered[p] += owed;
            outstanding[p] = 0;
        }
        assertEq(address(recipient).balance - beforePaid, rejecting ? 0 : owed);
    }

    function _coreDelta(Vm.Log[] memory logs, PoolId id) private view returns (int128 eth, int128 imd) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                assertEq(logs[i].topics[1], PoolId.unwrap(id));
                (eth, imd,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return (eth, imd);
            }
        }
        revert("missing core Swap event");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract LilyGuardLifecycleInvariantTest is LilyGuardTestBase {
    using StateLibrary for IPoolManager;

    LilyGuardLifecycleHandler private lifecycle;
    PoolKey[3] private keys;
    uint256 private initialETH;
    uint256 private initialSupply;
    uint256 private initialRecipientETH;

    function setUp() public override {
        super.setUp();
        vm.etch(OWNER, address(new RecipientProbe()).code);
        keys[0] = key;
        keys[1] = _key(3_000, 10);
        keys[2] = _key(12_500, 60);
        manager.initialize(keys[1], Q96);
        manager.initialize(keys[2], Q96);
        lifecycle = new LilyGuardLifecycleHandler(manager, hook, keys);
        for (uint256 a; a < 3; ++a) {
            address trader = address(lifecycle.actors(a));
            vm.deal(trader, 100_000 ether);
            imd.mint(trader, 100_000 ether);
        }
        lifecycle.seed();
        initialRecipientETH = OWNER.balance;
        initialETH = _totalETH();
        initialSupply = imd.totalSupply();

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = LilyGuardLifecycleHandler.swap.selector;
        selectors[1] = LilyGuardLifecycleHandler.changeLiquidity.selector;
        selectors[2] = LilyGuardLifecycleHandler.collect.selector;
        selectors[3] = LilyGuardLifecycleHandler.setPaused.selector;
        selectors[4] = LilyGuardLifecycleHandler.unauthorizedPause.selector;
        selectors[5] = LilyGuardLifecycleHandler.setRecipientRejection.selector;
        selectors[6] = LilyGuardLifecycleHandler.claim.selector;
        targetSelector(FuzzSelector(address(lifecycle), selectors));
        targetContract(address(lifecycle));
    }

    function invariant_claimsAndPauseAreIsolatedByTheEntirePoolId() public view {
        uint256 totalClaims;
        uint256 totalDelivered;
        for (uint256 p; p < 3; ++p) {
            uint256 outstanding = lifecycle.outstanding(p);
            uint256 delivered = lifecycle.delivered(p);
            assertEq(hook.pendingFees(keys[p].toId()), outstanding, "per-pool claim ledger");
            assertEq(lifecycle.accrued(p), delivered + outstanding, "per-pool fee conservation");
            assertEq(hook.paused(keys[p].toId()), lifecycle.expectedPaused(p));
            totalClaims += outstanding;
            totalDelivered += delivered;
        }
        assertEq(manager.balanceOf(address(hook), 0), totalClaims);
        assertEq(OWNER.balance - initialRecipientETH, totalDelivered);
    }

    function test_lifecycleExitsAfterRejectedPayoutsPausesAndCompleteWithdrawals() public {
        lifecycle.setRecipientRejection(true);
        lifecycle.swap(0, 1, uint96(0.01 ether), true);
        lifecycle.swap(1, 2, uint96(0.01 ether), false);
        assertGt(lifecycle.outstanding(0), 0);
        assertGt(lifecycle.outstanding(1), 0);
        assertEq(lifecycle.outstanding(2), 0);
        lifecycle.changeLiquidity(2, 1, uint96(5 ether), false, false);
        lifecycle.changeLiquidity(0, 0, 0, true, true);
        assertEq(lifecycle.liquidity(0, 0), 0);
        lifecycle.setPaused(0, true);
        lifecycle.unauthorizedPause(0, 2, false);
        lifecycle.claim(0, 2); // A failed payout must preserve this pool's entire claim.
        invariant_claimsAndPauseAreIsolatedByTheEntirePoolId();
        invariant_multipleTradersConserveETHAndTheExistingTokenSupply();
        afterInvariant();
    }

    function invariant_multipleTradersConserveETHAndTheExistingTokenSupply() public view {
        assertEq(_totalETH(), initialETH, "ETH conservation across all actors");
        uint256 sum =
            imd.balanceOf(address(manager)) + imd.balanceOf(address(hook)) + imd.balanceOf(address(actor));
        for (uint256 a; a < 3; ++a) {
            sum += imd.balanceOf(address(lifecycle.actors(a)));
        }
        assertEq(sum, initialSupply, "IMD conservation across all actors");
        assertEq(imd.totalSupply(), initialSupply, "hook changed the existing supply");
        assertEq(address(hook).balance, 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        _assertSettled();
    }

    function afterInvariant() public {
        lifecycle.exitAll();
        invariant_claimsAndPauseAreIsolatedByTheEntirePoolId();
        invariant_multipleTradersConserveETHAndTheExistingTokenSupply();
        for (uint256 p; p < 3; ++p) {
            assertEq(hook.pendingFees(keys[p].toId()), 0, "claims not redeemable after sequence");
            assertEq(manager.getLiquidity(keys[p].toId()), 0, "LP could not exit while paused");
        }
    }

    function _totalETH() private view returns (uint256 total) {
        total = address(manager).balance + address(hook).balance + OWNER.balance;
        for (uint256 a; a < 3; ++a) {
            total += address(lifecycle.actors(a)).balance;
        }
    }
}
