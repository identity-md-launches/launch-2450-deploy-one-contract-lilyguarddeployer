// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LilyGuard} from "../src/LilyGuard.sol";
import {LilyGuardTestBase} from "./LilyGuardTestBase.sol";

contract LilyGuardSwapsTest is LilyGuardTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        actor.modify(key, -600, 600, int256(uint256(LIQUIDITY)));
    }

    function test_buyExactETHInput() public {
        (BalanceDelta result,, uint256 fee) = _assertSwap(key, _params(true, -1 ether));
        assertEq(result.amount0(), -1 ether);
        assertGt(result.amount1(), 0);
        assertEq(fee, 0.01 ether);
        assertEq(hook.pendingFees(key.toId()), 0);
    }

    function test_buyExactIMDOutput() public {
        (BalanceDelta result,, uint256 fee) = _assertSwap(key, _params(true, 1 ether));
        assertEq(result.amount1(), 1 ether);
        assertLt(result.amount0(), 0);
        assertGt(fee, 0);
    }

    function test_sellExactIMDInput() public {
        (BalanceDelta result,, uint256 fee) = _assertSwap(key, _params(false, -1 ether));
        assertEq(result.amount1(), -1 ether);
        assertGt(result.amount0(), 0);
        assertGt(fee, 0);
    }

    function test_sellExactETHOutput() public {
        (BalanceDelta result,, uint256 fee) = _assertSwap(key, _params(false, 1 ether));
        assertEq(result.amount0(), 1 ether);
        assertLt(result.amount1(), 0);
        assertEq(fee, 0.01 ether);
    }

    function test_partialETHInputRevertsAndRollsBackEverything() public {
        _assertPartialReverts(true);
    }

    function test_partialETHOutputRevertsAndRollsBackEverything() public {
        _assertPartialReverts(false);
    }

    function _assertPartialReverts(bool buy) internal {
        uint256 recipientBefore = OWNER.balance;
        uint256 actorETHBefore = address(actor).balance;
        uint256 actorIMDBefore = imd.balanceOf(address(actor));
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        SwapParams memory params = SwapParams(
            buy,
            buy ? -int256(1 ether) : int256(1 ether),
            TickMath.getSqrtPriceAtTick(buy ? int24(-1) : int24(1))
        );
        try actor.swap(key, params) {
            revert("partial ETH fill accepted");
        } catch (bytes memory reason) {
            _assertHookError(reason, IHooks.afterSwap.selector, LilyGuard.PartialETHFill.selector);
        }
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceAfter, priceBefore);
        assertEq(OWNER.balance, recipientBefore);
        assertEq(address(actor).balance, actorETHBefore);
        assertEq(imd.balanceOf(address(actor)), actorIMDBefore);
        assertEq(hook.pendingFees(key.toId()), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        _assertSettled();
    }

    function test_partialTokenInputChargesOnlyExecutedETH() public {
        SwapParams memory params = SwapParams(false, -1 ether, TickMath.getSqrtPriceAtTick(1));
        (BalanceDelta result,,) = _assertSwap(key, params);
        assertGt(result.amount1(), -1 ether, "partial token input");
        assertLt(result.amount1(), 0);
    }

    function test_partialTokenOutputChargesOnlyExecutedETH() public {
        SwapParams memory params = SwapParams(true, 1 ether, TickMath.getSqrtPriceAtTick(-1));
        (BalanceDelta result,,) = _assertSwap(key, params);
        assertLt(result.amount1(), 1 ether, "partial token output");
        assertGt(result.amount1(), 0);
    }

    function test_feesRoundDownToWei() public {
        (,, uint256 belowOneWei) = _assertSwap(key, _params(true, -99));
        assertEq(belowOneWei, 0);
        (,, uint256 oneWei) = _assertSwap(key, _params(true, -100));
        assertEq(oneWei, 1);
    }

    function test_pauseOnlyStopsItsPoolSwapsAndUnpauseRestoresThem() public {
        PoolKey memory other = _key(12_500, 60);
        manager.initialize(other, Q96);
        actor.modify(other, -600, 600, int256(uint256(LIQUIDITY)));
        vm.prank(OWNER);
        hook.pause(key.toId());
        assertTrue(hook.paused(key.toId()));
        assertFalse(hook.paused(other.toId()));
        vm.expectRevert();
        actor.swap(key, _params(true, -1 ether));
        vm.expectRevert();
        actor.swap(key, _params(false, -1 ether));
        _assertSwap(other, _params(true, -1 ether));
        vm.prank(OWNER);
        hook.unpause(key.toId());
        _assertSwap(key, _params(true, -1 ether));
        assertFalse(hook.paused(key.toId()));
    }

    function test_removeLiquidityAndCollectWhilePaused() public {
        _assertSwap(key, _params(true, -1 ether));
        vm.prank(OWNER);
        hook.pause(key.toId());
        uint256 beforeFeeRecipient = OWNER.balance;
        BalanceDelta collect = actor.modify(key, -600, 600, 0);
        assertGe(collect.amount0(), 0);
        assertGe(collect.amount1(), 0);
        BalanceDelta removed = actor.modify(key, -600, 600, -int256(uint256(LIQUIDITY)));
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        assertEq(OWNER.balance, beforeFeeRecipient, "no hook fee on removals or collects");
        assertEq(manager.getLiquidity(key.toId()), 0);
        _assertSettled();
    }

    function test_addLiquidityAndDonateWhilePaused() public {
        vm.prank(OWNER);
        hook.pause(key.toId());
        actor.modify(key, -600, 600, 1 ether);
        actor.donate(key, 0.1 ether, 0.1 ether);
        assertEq(hook.pendingFees(key.toId()), 0);
        _assertSettled();
    }

    function testFuzz_allSwapModesConserveFunds(uint96 rawAmount, uint8 mode) public {
        uint256 amount = bound(uint256(rawAmount), 100, 2 ether);
        bool buy = mode % 4 < 2;
        bool exactInput = mode % 2 == 0;
        _assertSwap(key, _params(buy, exactInput ? -int256(amount) : int256(amount)));
    }

    function testFuzz_pauseIsolation(uint24 rawFee) public {
        uint24 fee = uint24(bound(rawFee, 3_001, 100_000));
        PoolKey memory other = _key(fee, 60);
        manager.initialize(other, Q96);
        vm.prank(OWNER);
        hook.pause(other.toId());
        assertTrue(hook.paused(other.toId()));
        assertFalse(hook.paused(key.toId()));
        assertEq(hook.token(other.toId()), IMD);
        assertEq(hook.token(key.toId()), IMD);
        _assertSwap(key, _params(false, -0.1 ether));
    }
}
